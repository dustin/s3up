module Main where

import           Control.Monad          (unless)
import           Control.Monad.IO.Class (MonadIO (..))
import           Data.Foldable          (fold)
import           Data.Maybe             (isNothing)
import           Network.AWS.S3         (ObjectKey (..))
import           Options.Applicative    (Parser, ReadM, argument, auto, command, execParser, fullDesc, help, helper,
                                         info, long, metavar, option, progDesc, readerError, short, showDefault,
                                         strOption, subparser, switch, value, (<**>))
import           System.Directory       (createDirectoryIfMissing, getHomeDirectory)
import           System.FilePath.Posix  ((</>))

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
    create = Create <$> argument auto (metavar "filename") <*> argument auto (metavar "objkey")
    abort = Abort <$> argument auto (metavar "objkey") <*> argument auto (metavar "uploadIID")


runCreate :: FilePath -> ObjectKey -> S3Up ()
runCreate filename key = do
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
runList = mapM_ printRemote =<< listMultiparts
  where printRemote (t,k,i) = liftIO . putStrLn $ fold ["- ", show t, " ", show k, " ID: ", show i]

run :: Command -> S3Up ()
run (Create f o) = runCreate f o
run Upload       = runUpload
run List         = runList
run (Abort o i)  = abortUpload o i

main :: IO ()
main = do
  confdir <- (</> ".config/s3up") <$> getHomeDirectory
  createDirectoryIfMissing True confdir
  o@Options{..} <- execParser (opts confdir)
  runWithOptions o (run optCommand)

  where
    opts confdir = info (options confdir <**> helper)
                ( fullDesc <> progDesc "S3 Upload utility.")
