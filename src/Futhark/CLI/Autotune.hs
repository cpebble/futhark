{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Futhark.CLI.Autotune (main) where

import Control.Monad
import qualified Data.ByteString.Char8 as SBS
import Data.Function (on)
import Data.Tree
import Data.List (intersect, isPrefixOf, sort, sortOn, elemIndex, minimumBy)
import Data.Maybe
import Text.Read (readMaybe)
import Text.Regex.TDFA
import qualified Data.Text as T
import qualified Data.Set as S

import System.Environment (getExecutablePath)
import System.Exit
import System.Process
import System.FilePath
import System.Console.GetOpt

import Futhark.Bench
import Futhark.Test
import Futhark.Util.Options

data AutotuneOptions = AutotuneOptions
                    { optBackend :: String
                    , optFuthark :: Maybe String
                    , optRuns :: Int
                    , optTuning :: Maybe String
                    , optExtraOptions :: [String]
                    , optVerbose :: Int
                    , optTimeout :: Int
                    }

initialAutotuneOptions :: AutotuneOptions
initialAutotuneOptions =
  AutotuneOptions "opencl" Nothing 10 (Just "tuning") [] 0 60

compileOptions :: AutotuneOptions -> IO CompileOptions
compileOptions opts = do
  futhark <- maybe getExecutablePath return $ optFuthark opts
  return $ CompileOptions { compFuthark = futhark
                          , compBackend = optBackend opts
                          , compOptions = mempty
                          }

runOptions :: Path -> Int -> AutotuneOptions -> RunOptions
runOptions path timeout_s opts =
  RunOptions { runRunner = ""
             , runRuns = optRuns opts
             , runExtraOptions = "-L" : map opt path ++ optExtraOptions opts
             , runTimeout = timeout_s
             , runVerbose = optVerbose opts
             }
  where opt (name, val) = "--size=" ++ name ++ "=" ++ show val

type Path = [(String, Int)]

regexGroups :: Regex -> String -> Maybe [String]
regexGroups regex s = do
  (_, _, _, groups) <-
    matchM regex s :: Maybe (String, String, String, [String])
  Just groups

comparisons :: String -> [(String,Int)]
comparisons = mapMaybe isComparison . lines
  where regex = makeRegex ("Compared ([^ ]+) <= (-?[0-9]+)" :: String)
        isComparison l = do [thresh, val] <- regexGroups regex l
                            val' <- readMaybe val
                            return (thresh, val')


type RunDataset = Int -> Path -> IO (Either String ([(String, Int)], Int))

type DatasetName = String

prepare :: AutotuneOptions -> FilePath -> IO [(DatasetName, RunDataset, T.Text)]
prepare opts prog = do
  spec <- testSpecFromFileOrDie prog
  copts <- compileOptions opts

  truns <-
    case testAction spec of
      RunCases ios _ _ | not $ null ios -> do
            when (optVerbose opts > 1) $
               putStrLn $
                 unwords ("Entry points:" : map (T.unpack . iosEntryPoint) ios)

            res <- prepareBenchmarkProgram Nothing copts prog ios
            case res of
              Left (err, errstr) -> do
                putStrLn err
                maybe (return ()) SBS.putStrLn errstr
                exitFailure
              Right () ->
                return ios
      _ ->
        fail "Unsupported test spec."

  let runnableDataset entry_point trun =
        case runExpectedResult trun of
          Succeeds expected
            | null (runTags trun `intersect` ["notune", "disable"]) ->
                Just (runDescription trun, run entry_point trun expected)

          _ -> Nothing

  fmap concat $ forM truns $ \ios ->
    forM (mapMaybe (runnableDataset $ iosEntryPoint ios)
                   (iosTestRuns ios)) $
      \(dataset, do_run) ->
        return (dataset, do_run, iosEntryPoint ios)

  where run entry_point trun expected timeout path = do
          let bestRuntime :: ([RunResult], T.Text) -> ([(String, Int)], Int)
              bestRuntime (runres, errout) =
                (comparisons (T.unpack errout),
                 minimum $ map runMicroseconds runres)

              ropts = runOptions path timeout opts

          when (optVerbose opts > 1) $
            putStrLn $ "Running with options: " ++ unwords (runExtraOptions ropts)

          either (Left . T.unpack) (Right . bestRuntime) <$>
            benchmarkDataset ropts prog entry_point
            (runInput trun) expected
            (testRunReferenceOutput prog entry_point trun)

--- Benchmarking a program

data DatasetResult = DatasetResult [(String, Int)] Double
             deriving Show

--- Finding initial comparisons.

--- Extracting threshold hierarchy.

type ThresholdForest = Forest (String, Bool)

thresholdMin, thresholdMax :: Int
thresholdMin = 1
thresholdMax = 2000000000

-- | Depth-first list of thresholds to tune in order, and a
-- corresponding assignment of ancestor thresholds to ensure that they
-- are used.
tuningPaths :: ThresholdForest -> [(String, Path)]
tuningPaths = concatMap (treePaths [])
  where treePaths ancestors (Node (v, _) children) =
          concatMap (onChild ancestors v) children ++ [(v, ancestors)]

        onChild ancestors v child@(Node (_, cmp) _) =
          treePaths (ancestors++[(v, t cmp)]) child

        t False = thresholdMax
        t True = thresholdMin

thresholdForest :: FilePath -> IO ThresholdForest
thresholdForest prog = do
  thresholds <- getThresholds <$>
    readProcess ("." </> dropExtension prog) ["--print-sizes"] ""
  let root (v, _) = ((v, False), [])
  return $ unfoldForest (unfold thresholds) $
    map root $ filter (null . snd) thresholds
  where getThresholds = mapMaybe findThreshold . lines
        regex = makeRegex ("(.*)\\ \\(threshold\\ \\((.*)\\)\\)" :: String)

        findThreshold :: String -> Maybe (String, [(String, Bool)])
        findThreshold l = do [grp1, grp2] <- regexGroups regex l
                             return (grp1,
                                     filter (not . null . fst) $
                                     map (\x -> if "!" `isPrefixOf` x
                                                then (drop 1 x, False)
                                                else (x, True)) $
                                     words grp2)

        unfold thresholds ((parent, parent_cmp), ancestors) =
          let ancestors' = parent : ancestors

              isChild (v, v_ancestors) = do
                cmp <- lookup parent v_ancestors
                guard $
                  sort (map fst v_ancestors) ==
                  sort (parent : ancestors)
                return ((v, cmp), ancestors')

          in ((parent, parent_cmp), mapMaybe isChild thresholds)

--- Doing the atual tuning

tuneThreshold :: AutotuneOptions
              -> [(DatasetName, RunDataset, T.Text)]
              -> Path -> (String, Path)
              -> IO Path
tuneThreshold opts datasets already_tuned (v, _v_path) = do
  (_, threshold) <-
    foldM tuneDataset (thresholdMin, thresholdMax) datasets
  return $ (v, threshold) : already_tuned

  where
    tuneDataset :: (Int, Int) -> (DatasetName, RunDataset, T.Text) -> IO (Int, Int)
    tuneDataset (tMin, tMax) (dataset_name, run, entry_point) =
      if not $ isPrefixOf (T.unpack entry_point ++ ".") v then do
        when (optVerbose opts > 0) $
          putStrLn $ unwords [v, "is irrelevant for", T.unpack entry_point]
        return (tMin, tMax)
      else do

        putStrLn $ unwords ["Tuning", v, "on entry point", T.unpack entry_point,
                             "and dataset", dataset_name]

        sample_run <- run (optTimeout opts) ((v, tMax) : already_tuned)

        case sample_run of
          Left err -> do
            -- If the sampling run fails, we treat it as zero information.
            -- One of our ancestor thresholds will have be set such that
            -- this path is never taken.
            when (optVerbose opts > 0) $ putStrLn $
              "Sampling run failed:\n" ++ err
            return (tMin, tMax)
          Right (cmps, t) -> do
            let ePars = S.toAscList $
                        S.map snd $
                        S.filter (candidateEPar (tMin, tMax)) $
                        S.fromList cmps

                runner :: Int -> Int -> IO (Maybe Int)
                runner timeout' threshold = do
                  res <- run timeout' ((v, threshold) : already_tuned)
                  case res of
                    Right (_, runTime) ->
                      return $ Just runTime
                    _ ->
                      return Nothing

            when (optVerbose opts > 1) $
              putStrLn $ unwords ("Got ePars: " : map show ePars)

            newMax <- binarySearch runner (t, tMax) ePars
            let newMinIdx = pred <$> elemIndex newMax ePars
            let newMin = maximum $ catMaybes [Just tMin, newMinIdx]
            return (newMin, newMax)

    bestPair :: [(Int, Int)] -> (Int, Int)
    bestPair = minimumBy (compare `on` fst)

    timeout :: Int -> Int
    -- We wish to let datasets run for the untuned time + 20% + 1 second.
    timeout elapsed = ceiling (fromIntegral elapsed * 1.2 :: Double) + 1

    candidateEPar :: (Int, Int) -> (String, Int) -> Bool
    candidateEPar (tMin, tMax) (threshold, ePar) =
      ePar > tMin && ePar < tMax && threshold == v


    binarySearch :: (Int -> Int -> IO (Maybe Int)) -> (Int, Int) -> [Int] -> IO Int
    binarySearch runner best@(best_t, best_e_par) xs =
      case splitAt (length xs `div` 2) xs of
        (lower, middle : middle' : upper) -> do
          when (optVerbose opts > 0) $
            putStrLn $ unwords ["Trying e_par", show middle,
                                "and", show middle']
          candidate <- runner (timeout best_t) middle
          candidate' <- runner (timeout best_t) middle'
          case (candidate, candidate') of
            (Just new_t, Just new_t') ->
              if new_t < new_t' then
                -- recurse into lower half
                binarySearch runner (bestPair [(new_t, middle), best]) lower
              else
                -- recurse into upper half
                binarySearch runner (bestPair [(new_t', middle'), best]) upper
            (Just new_t, Nothing) ->
              -- recurse into lower half
              binarySearch runner (bestPair [(new_t, middle), best]) lower
            (Nothing, Just new_t') ->
                -- recurse into upper half
                binarySearch runner (bestPair [(new_t', middle'), best]) upper
            (Nothing, Nothing) -> do
              when (optVerbose opts > 2) $
                putStrLn $ unwords ["Timing failed for candidates",
                                    show middle, "and", show middle']
              return best_e_par
        (_, []) -> return best_e_par
        (_, [x]) -> do
          when (optVerbose opts > 0) $
            putStrLn $ unwords ["Trying e_par", show x]
          candidate <- runner (timeout best_t) x
          case candidate of
            Just new_t ->
              return $ snd $ bestPair [(new_t, x), best]
            Nothing ->
              return best_e_par

--- CLI

tune :: AutotuneOptions -> FilePath -> IO Path
tune opts prog = do
  putStrLn $ "Compiling " ++ prog ++ "..."
  datasets <- prepare opts prog

  forest <- thresholdForest prog
  when (optVerbose opts > 0) $
    putStrLn $ ("Threshold forest:\n"++) $ drawForest $ map (fmap show) forest

  foldM (tuneThreshold opts datasets) [] $ tuningPaths forest

runAutotuner :: AutotuneOptions -> FilePath -> IO ()
runAutotuner opts prog = do
  best <- tune opts prog

  let tuning = unlines $ do (s, n) <- sortOn fst best
                            return $ s ++ "=" ++ show n

  case optTuning opts of
    Nothing -> return ()
    Just suffix -> do
      writeFile (prog <.> suffix) tuning
      putStrLn $ "Wrote " ++ prog <.> suffix

  putStrLn $ "Result of autotuning:\n" ++ tuning

commandLineOptions :: [FunOptDescr AutotuneOptions]
commandLineOptions = [
    Option "r" ["runs"]
    (ReqArg (\n ->
              case reads n of
                [(n', "")] | n' >= 0 ->
                  Right $ \config ->
                  config { optRuns = n'
                         }
                _ ->
                  Left $ error $ "'" ++ n ++ "' is not a non-negative integer.")
     "RUNS")
    "Run each test case this many times."
  , Option [] ["backend"]
    (ReqArg (\backend -> Right $ \config -> config { optBackend = backend })
     "BACKEND")
    "The compiler used (defaults to 'opencl')."
  , Option [] ["futhark"]
    (ReqArg (\prog -> Right $ \config -> config { optFuthark = Just prog })
     "PROGRAM")
    "The binary used for operations (defaults to 'futhark')."
  , Option [] ["tuning"]
    (ReqArg (\s -> Right $ \config -> config { optTuning = Just s })
    "EXTENSION")
    "Write tuning files with this extension (default: .tuning)."
  , Option [] ["timeout"]
    (ReqArg (\n ->
               case reads n of
                 [(n', "")] ->
                   Right $ \config -> config { optTimeout = n' }
                 _ ->
                   Left $ error $ "'" ++ n ++ "' is not a non-negative integer.")
    "SECONDS")
    "Initial tuning timeout for each dataset. Later tuning runs are based off of the runtime of the first run."
  , Option "v" ["verbose"]
    (NoArg $ Right $ \config -> config { optVerbose = optVerbose config + 1 })
    "Enable logging.  Pass multiple times for more."
   ]

main :: String -> [String] -> IO ()
main = mainWithOptions initialAutotuneOptions commandLineOptions
       "options... program" $
       \progs config ->
         case progs of [prog] -> Just $ runAutotuner config prog
                       _      -> Nothing
