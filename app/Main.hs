{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns  #-}

module Main where

import           Amazonka                             (ToText (..))
import           Amazonka.S3                          (ObjectKey (..), StorageClass (..))
import           Control.Applicative                  ((<|>))
import           Control.Monad                        (unless, when)
import           Control.Monad.Catch                  (SomeException (..), bracket_, catch)
import           Control.Monad.IO.Class               (MonadIO (..))
import           Control.Monad.Reader                 (asks)
import           Data.Char                            (toLower)
import           Data.Foldable                        (fold, traverse_)
import           Data.List                            (intercalate, partition, sortOn)
import           Data.List.NonEmpty                   (NonEmpty (..))
import qualified Data.List.NonEmpty                   as NE
import qualified Data.Map.Strict                      as Map
import           Data.Maybe                           (isNothing)
import qualified Data.Set                             as Set
import qualified Data.Text                            as T
import           Options.Applicative                  (Parser, ReadM, argument, auto, command, customExecParser,
                                                       eitherReader, fullDesc, help, helper, info, long, metavar,
                                                       option, prefs, progDesc, readerError, short, showDefault,
                                                       showHelpOnError, some, str, strOption, subparser, switch, value,
                                                       (<**>))
import           Options.Applicative.Help.Levenshtein (editDistance)
import           System.Directory                     (createDirectoryIfMissing, getHomeDirectory)
import           System.FilePath.Posix                ((</>))
import           System.IO                            (BufferMode (..), hFlush, hGetBuffering, hGetEcho, hSetBuffering,
                                                       hSetEcho, stdin, stdout)
import           UnliftIO                             (mapConcurrently)

import           S3Up
import qualified S3Up.DB                              as DB
import           S3Up.Logging
import           S3Up.Types

atLeast :: (Read n, Show n, Ord n, Num n) => n -> ReadM n
atLeast n = auto >>= \i -> if i >= n then pure i else readerError ("must be at least " <> show n)

options :: FilePath -> Parser Options
options confdir = Options
  <$> strOption (long "dbpath" <> showDefault <> value (confdir </> "s3up.db") <> help "db path")
  <*> strOption (long "bucket" <> showDefault <> value "junk.west.spy.net" <> help "s3 bucket")
  <*> option (atLeast (5*1024*1024)) (short 's' <> long "chunk-size" <> showDefault
                                      <> value (6 * 1024 * 1024) <> help "upload chunk size")
  <*> option sclass (short 'c' <> long "storage-class" <> showDefault
                     <> value StorageClass_STANDARD <> help "storage class")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (atLeast 1) (short 'u' <> long "upload-concurrency" <> showDefault
                          <> value 3 <> help "Upload concurrency")
  <*> option (atLeast 1) (long "create-concurrency" <> showDefault
                          <> value 1 <> help "Create concurrency")
  <*> option hook (long "post-upload-hook"
                          <> value KeepFile <> help "Hook to run after upload completes (keep | delete)")
  <*> subparser ( command "create" (info create (progDesc "Create a new upload"))
                  <> command "upload" (info (pure Upload) (progDesc "Upload outstanding data"))
                  <> command "list" (info (pure List) (progDesc "List current uploads"))
                  <> command "abort" (info abort (progDesc "Abort an upload"))
                )
  where
    create = Create . parseDests <$> some (argument str (metavar "file objkey || file... objkey/"))

    abort = Abort <$> argument str (metavar "objkey") <*> argument str (metavar "uploadID")
            <|> pure InteractiveAbort
    classes = [("onezone-ia", StorageClass_ONEZONE_IA),
               ("rr", StorageClass_REDUCED_REDUNDANCY),
               ("standard", StorageClass_STANDARD),
               ("standard-ia", StorageClass_STANDARD_IA)]
    sclass = eitherReader $ \s -> maybe (Left (inv "StorageClass" s (fst <$> classes))) Right $ lookup s classes

    hooks = [("keep", KeepFile), ("delete", DeleteFile)]
    hook = eitherReader $ \s -> maybe (Left (inv "upload hook" s (fst <$> hooks))) Right $ lookup s hooks

    parseDests [] = Left "insufficient arguments"
    parseDests [_] = Left "insufficient arguments"
    parseDests [x,d] = Right ((x, mkObjectKey x d) :| [])
    parseDests (reverse -> (d:xs))
      | isDir d && all isFile xs = Right . NE.fromList $ map (\x -> (x, mkObjectKey x d)) xs
      | otherwise = Left "final parameter must be an object ending in /"
      where
        isDir ""                   = False
        isDir (reverse -> ('/':_)) = True
        isDir _                    = False
        isFile = not . isDir

    bestMatch n = head . sortOn (editDistance n)
    inv t v vs = fold ["invalid ", t, ": ", show v, ", perhaps you meant: ", bestMatch v vs,
                        "\nValid values:  ", intercalate ", " vs]

some1 :: Parser a -> Parser (NonEmpty a)
some1 p = NE.fromList <$> some p

runCreate :: Either String (NonEmpty (FilePath, ObjectKey)) -> S3Up ()
runCreate (Left e) = logErrorL ["Invalid paths for create: ", T.pack e]
runCreate (Right xs) = do
  bn <- asks (optBucket . s3Options)
  inflight <- Set.fromList . fmap (\(_,b,k) -> (b,k)) <$> DB.listQueuedFiles
  let (doing, todo) = partition (\(_,k) -> (bn,k) `Set.member` inflight) (NE.toList xs)
  traverse_ (\(fp,ok) -> logInfoL ["Skipping in-flight upload of ", tshow fp, " -> ", tshow ok]) doing
  c <- asks (optCreateConcurrency . s3Options)
  hook <- asks (optHook . s3Options)
  mapConcurrentlyLimited_ c (one hook) todo

  where
    one hook (filename, key) = do
      PartialUpload{..} <- createMultipart hook filename key
      logDbgL ["Created upload for ", tshow _pu_bucket, ":", tshow _pu_key, " in ",
               tshow (length _pu_parts), " parts as ", _pu_upid]
      logInfo "Upload created.  Use the 'upload' command to complete."

runUpload :: S3Up ()
runUpload = do
  todo <- DB.listPartialUploads
  unless (null todo) $ logInfoL [tshow (length todo), " files to upload for a total of about ",
                                 tshow (todoMB todo), " MB"]
  mapM_ completeUpload todo
  where todoMB = sum . fmap (\PartialUpload{..}
                             -> mb $ _pu_chunkSize * (toInteger . length . filter (isNothing . snd) $ _pu_parts))
        mb = (`div` (1024*1024))

runList :: S3Up ()
runList = do
  local <- Map.fromList . fmap (\pu@PartialUpload{..} -> ((_pu_bucket, _pu_upid), pu)) <$> DB.listPartialUploads
  mapM_ (printBucket local) =<< mapConcurrently (\b -> (b,) <$> tryList b) =<< allBuckets
  where
    pl = liftIO . putStrLn . fold
    tryList b = listMultiparts b `catch` listErr
      where
        listErr (SomeException e) = do
          logErrorL ["Failed loading multiparts from ", tshow b, ": ", tshow e]
          pure []
    printBucket _ (_,[]) = pure ()
    printBucket m (b,xs) = pl ["In bucket: ", T.unpack (toText b)] >> mapM_ printRemote xs
      where
        printRemote (t,k,i) = pl (["- ", show t,
                                  "\n  ", (maybe "(unmanaged)" completeStr $ Map.lookup (b,i) m),
                                  "\n  ", show k]
                                  <> (maybe [] localParts (Map.lookup (b,i) m))
                                  <> ["\n  ID: ", show i])
    localParts PartialUpload{..} = [
      "\n  ", _pu_filename,
      "\n  hook: ", show _pu_hook
      ]

prompt :: MonadIO m => String -> m Bool
prompt s = liftIO (putStr s >> hFlush stdout >> bufd wait)

    where
      wait = do
        x <- getChar
        case toLower x of
          'y'  -> pure True
          'n'  -> pure False
          '\n' -> pure False
          _    -> wait

      bufd a = do
        olde <- hGetEcho stdin
        oldb <- hGetBuffering stdin
        bracket_ (hSetEcho stdin False >> hSetBuffering stdin NoBuffering)
          (hSetEcho stdin olde >> hSetBuffering stdin oldb) a

runInteractiveAbort :: S3Up ()
runInteractiveAbort = mapM_ askAbort =<< listMultiparts =<< asks (optBucket . s3Options)
  where
    askAbort (t,k,i) = do
      liftIO . putStrLn $ fold [show t, " ", show k]
      shouldAbort <- prompt "delete? (y/N) "
      liftIO (putStrLn "")
      when shouldAbort $ logInfoL ["Deleting ", tshow i] >> abortUpload k i

run :: Command -> S3Up ()
run (Create l)       = runCreate l
run Upload           = runUpload
run List             = runList
run (Abort o i)      = abortUpload o i
run InteractiveAbort = runInteractiveAbort

main :: IO ()
main = do
  confdir <- (</> ".config/s3up") <$> getHomeDirectory
  createDirectoryIfMissing True confdir
  o@Options{..} <- customExecParser (prefs showHelpOnError) (opts confdir)
  runWithOptions o (run optCommand)

  where
    opts confdir = info (options confdir <**> helper)
                ( fullDesc <> progDesc "S3 Upload utility.")
