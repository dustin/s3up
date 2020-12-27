module Main where

import           Control.Monad          (unless)
import           Control.Monad.IO.Class (MonadIO (..))
import           Control.Monad.Reader   (asks)
import           Data.Foldable          (fold)
import           Data.List              (intercalate)
import           Data.Maybe             (fromMaybe, isNothing)
import           Data.String            (fromString)
import           Options.Applicative    (Parser, ReadM, argument, auto, execParser, fullDesc, help, helper, info, long,
                                         metavar, option, progDesc, readerError, short, showDefault, some, str,
                                         strOption, switch, value, (<**>))
import           System.Directory       (createDirectoryIfMissing, getHomeDirectory)
import           System.FilePath.Posix  ((</>))

import           S3Up
import           S3Up.DB
import           S3Up.Logging

atLeast :: (Read n, Show n, Ord n, Num n) => n -> ReadM n
atLeast n = auto >>= \i -> if (i >= n) then pure i else readerError ("must be at least " <> (show n))

options :: FilePath -> Parser Options
options confdir = Options
  <$> strOption (long "dbpath" <> showDefault <> value (confdir </> "s3up.db") <> help "db path")
  <*> strOption (long "bucket" <> showDefault <> value "junk.west.spy.net" <> help "s3 bucket")
  <*> option (atLeast (5*1024*1024)) (short 's' <> long "chunk-size" <> showDefault
                                      <> value (6 * 1024 * 1024) <> help "upload chunk size")
  <*> switch (short 'v' <> long "verbose" <> help "enable debug logging")
  <*> option (atLeast 1) (short 'u' <> long "upload-concurrency" <> showDefault
                          <> value 3 <> help "Upload concurrency")
  <*> some (argument str (metavar "cmd args..."))

runCreate :: S3Up ()
runCreate = do
  argv <- asks (optArgv . s3Options)
  unless (length argv == 2) $ fail "filename and destination key required"
  let [filename, key] = argv
  PartialUpload{..} <- createMultipart filename (fromString key)
  logInfoL ["Created upload for ", tshow _pu_bucket, ":", tshow _pu_key, " in ",
            tshow (length _pu_parts), " parts as ", _pu_upid]

runUpload :: S3Up ()
runUpload = do
  todo <- listPartialUploads
  unless (null todo) $ logInfoL [tshow (length todo), " files to upload for a total of about ",
                                 tshow (todoMB todo), " MB"]
  mapM_ completeUpload todo
  where todoMB = sum . fmap (\PartialUpload{..}
                             -> mb $ _pu_chunkSize * (toInteger . length . filter (isNothing . snd) $ _pu_parts))
        mb = (`div` (1024*1024))

runList :: S3Up ()
runList = do
  ps <- listMultiparts
  mapM_ printRemote ps

  where
    printRemote (t,k,i) = liftIO . putStrLn $ fold ["- ", show t, " ", show k, " ID: ", show i]

runAbort :: S3Up ()
runAbort = do
  argv <- asks (optArgv . s3Options)
  unless (length argv == 2) $ fail "key and upload ID required"
  let [keyS, upIDS] = argv
  abortUpload (fromString keyS) (fromString upIDS)

run :: String -> S3Up ()
run c = fromMaybe (liftIO unknown) $ lookup c cmds
  where
    cmds = [("create", runCreate),
            ("upload", runUpload),
            ("list", runList),
            ("abort", runAbort)
           ]
    unknown = do
      putStrLn $ "Unknown command: " <> c
      putStrLn "Try one of these:"
      putStrLn $ "    " <> intercalate "\n    " (map fst cmds)

main :: IO ()
main = do
  confdir <- (</> ".config/s3up") <$> getHomeDirectory
  createDirectoryIfMissing True confdir
  o@Options{..} <- execParser (opts confdir)
  runWithOptions o (run (head optArgv))

  where
    opts confdir = info (options confdir <**> helper)
                ( fullDesc <> progDesc "S3 Upload utility.")
