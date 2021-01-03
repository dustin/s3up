{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns  #-}

module Main where

import           Control.Applicative    ((<|>))
import           Control.Monad          (unless, when)
import           Control.Monad.Catch    (bracket_)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader   (asks)
import           Data.Char              (toLower)
import           Data.Foldable          (fold)
import qualified Data.Map.Strict        as Map
import           Data.Maybe             (isNothing)
import qualified Data.Text              as T
import           Network.AWS.Data.Text  (ToText (..))
import           Network.AWS.S3         (ObjectKey (..))
import           Options.Applicative    (Parser, ReadM, argument, auto, command, customExecParser, fullDesc, help,
                                         helper, info, long, metavar, option, prefs, progDesc, readerError, short,
                                         showDefault, showHelpOnError, str, strOption, subparser, switch, value, (<**>))
import           System.Directory       (createDirectoryIfMissing, getHomeDirectory)
import           System.FilePath.Posix  ((</>))
import           System.IO              (BufferMode (..), hFlush, hGetBuffering, hGetChar, hGetEcho, hSetBuffering,
                                         hSetEcho, stdin, stdout)
import           UnliftIO               (mapConcurrently)

import           S3Up
import qualified S3Up.DB                as DB
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
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (atLeast 1) (short 'u' <> long "upload-concurrency" <> showDefault
                          <> value 3 <> help "Upload concurrency")
  <*> subparser ( command "create" (info create (progDesc "Create a new upload"))
                  <> command "upload" (info (pure Upload) (progDesc "Upload outstanding data"))
                  <> command "list" (info (pure List) (progDesc "List current uploads"))
                  <> command "abort" (info abort (progDesc "Abort an upload"))
                )
  where
    create = Create <$> argument str (metavar "filename") <*> argument str (metavar "objkey")
    abort = Abort <$> argument str (metavar "objkey") <*> argument str (metavar "uploadID")
            <|> pure InteractiveAbort


runCreate :: FilePath -> ObjectKey -> S3Up ()
runCreate filename (mkObjectKey filename -> key) = do
  PartialUpload{..} <- createMultipart filename key
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
  local <- Map.fromList . fmap (\pu@PartialUpload{..} -> ((_pu_bucket, _pu_upid), completeStr pu)) <$> DB.listPartialUploads
  mapM_ (printBucket local) =<< mapConcurrently (\b -> (b,) <$> tryList b) =<< allBuckets
  where
    pl = liftIO . putStrLn . fold
    tryList b = listMultiparts b <|> (logErrorL ["Failed loading multiparts from ", tshow b] >> pure [])
    printBucket _ (_,[]) = pure ()
    printBucket m (b,xs) = pl ["In bucket: ", T.unpack (toText b)] >> mapM_ printRemote xs
      where
        printRemote (t,k,i) = pl ["- ", show t,
                                  "\n  ", scomp m (b,i),
                                  "\n  ", show k,
                                  "\n  ID: ", show i]
    scomp m i = Map.findWithDefault "(unmanaged)" i m

prompt :: MonadIO m => String -> m Bool
prompt s = liftIO (putStr s >> hFlush stdout >> bufd wait)

    where
      wait = do
        x <- hGetChar stdin
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
run (Create f o)     = runCreate f o
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
