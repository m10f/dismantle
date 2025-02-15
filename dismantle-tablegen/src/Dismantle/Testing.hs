{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Provide some tools for testing disassemblers
module Dismantle.Testing (
  ArchTestConfig(..),
  Instruction(..),
  InstructionLayout(..),
  binaryTestSuite,
  withDisassembledFile
  ) where

import Data.Char ( intToDigit )
import Data.Maybe ( fromMaybe )
import Data.Word ( Word8, Word64 )
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Foldable as F
import qualified Data.List as L
import Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.IO as TL
import Numeric ( showIntAtBase )
import System.FilePath.Glob ( namesMatching )
import System.FilePath ( (</>) )
import qualified System.Process as Proc
import qualified Text.Megaparsec as P
import System.IO (hClose)
import qualified Dismantle.Testing.Regex as RE
import qualified Text.PrettyPrint.HughesPJClass as PP
import Text.Printf ( printf )

import qualified Test.Tasty as T
import qualified Test.Tasty.HUnit as T

import Dismantle.Testing.Parser
import Dismantle.Tablegen.ISA (ISA(isaInputEndianness, isaName), Endianness(Little))

import Prelude

-- | Configuration to drive the shared testing infrastructure
data ArchTestConfig = forall i .
  ATC { testingISA :: ISA
      -- ^ The ISA associated with the test input
      , disassemble :: LBS.ByteString -> (Int, Maybe i)
      -- ^ The disassembly function for the ISA
      , assemble :: i -> LBS.ByteString
      -- ^ The re-assembly function for the ISA
      , prettyPrint :: i -> PP.Doc
      -- ^ The pretty printer for the ISA
      , expectFailure :: Maybe RE.Regex
      -- ^ A regular expression run against the text of an instruction (from
      -- objdump); if the regular expression matches, disassembly and reassembly
      -- are expected to fail (and the pretty printing check is therefore not
      -- run).
      , instructionFilter :: Instruction -> Bool
      -- ^ A function to determine which parsed instructions should be
      -- tested.
      , skipPrettyCheck :: Maybe RE.Regex
      -- ^ A regular expression run against the text of an instruction (from
      -- objdump); if the regular expression matches, the output of the pretty
      -- printer is not compared against the original text provided by objdump.
      , ignoreAddresses :: [(FilePath, [Word64])]
      -- ^ A list of files and addresses in those files to ignore. This
      -- is typically used when we know that some locations contain data
      -- bytes and we don't want to test instruction parses of those
      -- bytes.
      , customObjdumpArgs :: [(FilePath, [String])]
      -- ^ Custom arguments to objdump to disassemble the specified file.
      -- Files not present in this mapping will be disassembled with
      -- default objdump arguments. Entries in this mapping must provide
      -- all arguments to objdump up to but not including the file name,
      -- so this includes the disassembly flag (-d/-D).
      , normalizePretty :: TL.Text -> TL.Text
      -- ^ A function to normalize a pretty-printed instruction to a
      -- form suitable for comparison. This typically needs to remove
      -- whitespace and special characters whose presence confounds
      -- pretty-print comparisons but is otherwise unimportant for
      -- comparison purposes.  Both the objdump and the dismantle
      -- disassembly output are normalized.
      , comparePretty :: Maybe (TL.Text -> TL.Text -> Bool)
      -- ^ If special comparison between the pretty forms of
      -- instruction disassembly is needed, supply that here; if
      -- Nothing, this simply uses == (instance Eq).
      }

addressIsIgnored :: ArchTestConfig -> FilePath -> Word64 -> Bool
addressIsIgnored atc file addr =
    case lookup file (ignoreAddresses atc) of
        Nothing -> False
        Just addrs -> addr `elem` addrs

-- | Given an architecture-specific configuration and a directory containing
-- binaries, run @objdump@ on each binary and then try to disassemble and
-- re-assemble each instruction in those binaries (as identified by @objdump@).
--
-- Additionally, the output of the automatically-generated pretty printer is
-- compared against the output of @objdump@ unless the 'skipPrettyCheck' regex
-- matches the instruction under test.
binaryTestSuite :: ArchTestConfig -> FilePath -> IO T.TestTree
binaryTestSuite atc dir = do
  binaries <- namesMatching (dir </> "*")
  tests <- mapM (mkDisassembledBinaryTest atc) binaries
  return (T.testGroup (isaName (testingISA atc)) tests)

mkDisassembledBinaryTest :: ArchTestConfig -> FilePath -> IO T.TestTree
mkDisassembledBinaryTest atc binaryPath = do
  return $ T.testCaseInfo binaryPath $ do
    let fileCustomArgs = lookup binaryPath (customObjdumpArgs atc)
    let filterInstruction = instructionFilter atc
    withDisassembledFile (isaInputEndianness (testingISA atc)) objdumpParser fileCustomArgs binaryPath $ \d -> do
      let insns = filter filterInstruction (concatMap instructions (sections d))
      testAgg <- F.foldrM (testInstruction atc binaryPath) emptyTestAggregate insns
      let ok = and [ null (testDisassemblyFailures testAgg)
                   , null (testRoundtripFailures testAgg)
                   , null (testPrettyFailures testAgg)
                   ]
      T.assertBool (formatTestFailure testAgg) ok
      return (printf "%s (%d/%d - tests/expected failures)" binaryPath (testCount testAgg) (testExpectedFailure testAgg))

testInstruction :: ArchTestConfig -> FilePath -> Instruction -> TestAggregate -> IO TestAggregate
testInstruction atc binaryPath i agg
  | addressIsIgnored atc binaryPath (insnAddress i) = return agg
  | otherwise =
    case atc of
      ATC { disassemble = disasm
          , assemble = asm
          , prettyPrint = pp
          , skipPrettyCheck = skipPPRE
          , expectFailure = expectFailureRE
          , normalizePretty = norm
          , comparePretty = pCmp
          } -> case maybe False (RE.hasMatches (insnText i)) expectFailureRE of
                 False -> testInstructionWith norm pCmp disasm asm pp skipPPRE i agg
                 True -> return (agg { testExpectedFailure = testExpectedFailure agg + 1
                                     , testCount = testCount agg + 1
                                     })

testInstructionWith :: (TL.Text -> TL.Text)
                    -> Maybe (TL.Text -> TL.Text -> Bool)
                    -> (LBS.ByteString -> (Int, Maybe i))
                    -> (i -> LBS.ByteString)
                    -> (i -> PP.Doc)
                    -> Maybe RE.Regex
                    -> Instruction
                    -> TestAggregate
                    -> IO TestAggregate
testInstructionWith norm pCmp disasm asm pp skipPPRE i agg = do
  let bytes = insnBytes i
  let (_consumed, minsn) = disasm bytes
  case minsn of
    Nothing -> return (agg { testDisassemblyFailures = i : testDisassemblyFailures agg
                           , testCount = testCount agg + 1
                           })
    Just insn -> do
      case bytes == asm insn of
        False -> do
          let !pretty = T.pack (show (pp insn))
          let !actualRep = T.pack (binaryRep bytes)
          let !asmRep = T.pack (binaryRep (asm insn))
          let failure = (i, pretty, actualRep, asmRep)
          return (agg { testRoundtripFailures = failure : testRoundtripFailures agg
                      , testCount = testCount agg + 1
                      })
        True
          | not (maybe False (RE.hasMatches (insnText i)) skipPPRE) ->
            case (let want = norm (insnText i)
                      got  = norm (TL.pack (show (pp insn)))
                  in case pCmp of
                       Nothing -> want == got
                       Just cmpf -> cmpf want got
                 ) of
              True -> return (agg { testCount = testCount agg + 1 })
              False -> do
                let !pretty = T.pack (show (pp insn))
                let failure = (i, pretty)
                return (agg { testPrettyFailures = failure : testPrettyFailures agg
                            , testCount = testCount agg + 1
                            })
          | otherwise -> return (agg { testCount = testCount agg + 1 })

data TestAggregate =
  TestAggregate { testDisassemblyFailures :: [Instruction]
                , testRoundtripFailures :: [(Instruction, T.Text, T.Text, T.Text)]
                , testPrettyFailures :: [(Instruction, T.Text)]
                , testCount :: !Int
                , testExpectedFailure :: !Int
                }

emptyTestAggregate :: TestAggregate
emptyTestAggregate = TestAggregate { testDisassemblyFailures = []
                                   , testRoundtripFailures = []
                                   , testPrettyFailures = []
                                   , testCount = 0
                                   , testExpectedFailure = 0
                                   }

formatTestFailure :: TestAggregate -> String
formatTestFailure ta = show doc
  where
    doc = PP.vcat [ "Disassembly failures:"
                  , PP.nest 2 (PP.vcat disasmFailures)
                  , "Roundtrip failures:"
                  , PP.nest 2 (PP.vcat roundtripFailures)
                  , "Pretty printing failures:"
                  , PP.nest 2 (PP.vcat prettyFailures)
                  , PP.hcat [ "Total: "
                            , PP.text (show $ testCount ta), " tests"
                            , ", failures: "
                            , PP.text (show $ length $ testDisassemblyFailures ta), " disassembly"
                            , ", ", PP.text (show $ length $ testRoundtripFailures ta), " round-trip"
                            , ", ", PP.text (show $ length $ testPrettyFailures ta), " pretty-printing"
                            ]
                  ]
    disasmFailures = [ PP.text (printf "Failed to disassemble %s (%s)" (binaryRep (insnBytes i)) (TL.unpack (insnText i)))
                     | i <- testDisassemblyFailures ta
                     ]
    roundtripFailures = [ PP.text (printf "Roundtrip %s (parsed as %s):\n\tOriginal Bytes: %s\n\tReassembled as: %s" (show (insnText i)) (show parsedAs) (show origBytes) (show reassembledBytes))
                        | (i, parsedAs, origBytes, reassembledBytes) <- testRoundtripFailures ta
                        ]
    prettyFailures = [ PP.text (printf "Pretty printing comparison failed (bytes: %s)\n\tExpected: '%s'\n\tActual:   '%s' " (binaryRep (insnBytes i)) (insnText i) actual)
                     | (i, actual) <- testPrettyFailures ta
                     ]

withDisassembledFile :: Endianness -> Parser Disassembly -> Maybe [String] -> FilePath -> (Disassembly -> IO a) -> IO a
withDisassembledFile endianness parser customArgs f k = do
  (_, Just hout, _, ph) <- Proc.createProcess p1
  t <- TL.hGetContents hout
  case P.runParser parser f t of
    Left err -> do
      hClose hout
      _ <- Proc.waitForProcess ph
      error $ P.errorBundlePretty err
    Right d -> do
      let rewriteDisassembly = case endianness of
                                 Little swapBytes _ -> fmap (rewriteSection swapBytes)
                                 _ -> id
          rewriteSection fn s = s { instructions = rewriteInstruction fn <$> instructions s }
          rewriteInstruction fn i = i { insnBytes = fn $ insnBytes i }
          d' = Disassembly { sections = rewriteDisassembly (sections d) }
      res <- k d'
      hClose hout
      _ <- Proc.waitForProcess ph
      return res
  where
    p0 = Proc.proc "objdump" args
    args = (fromMaybe defaultArgs customArgs) <> [f]
    defaultArgs = ["-d"]
    p1 = p0 { Proc.std_out = Proc.CreatePipe
            }

showByte :: Word8 -> String
showByte b =
    let s = showIntAtBase 2 intToDigit b ""
        padding = replicate (8 - length s) '0'
    in padding <> s

binaryRep :: LBS.ByteString -> String
binaryRep bytes = L.intercalate "." $ showByte <$> LBS.unpack bytes
