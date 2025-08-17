{-# LANGUAGE BlockArguments       #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedLabels     #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns         #-}

module Main where

import           Amazonka                             (newEnv, runResourceT, send)
import           Amazonka.Auth                        (discover)
import           Amazonka.Data.Text                   (ToText (..))
import           Amazonka.S3                          (ObjectKey, StorageClass (..))
import qualified Amazonka.S3                          as S3
import           Cleff                                hiding (send)
import           Cleff.Error
import           Control.Applicative                  ((<|>))
import           Control.Lens                         hiding (List, argument)
import           Control.Monad                        (unless, void, when)
import           Control.Monad.Catch                  (SomeException (..), bracket_, catch)
import           Data.Char                            (toLower)
import           Data.Foldable                        (fold, traverse_)
import           Data.Generics.Labels                 ()
import           Data.List                            (intercalate, partition, sortOn)
import           Data.List.NonEmpty                   (NonEmpty (..))
import qualified Data.List.NonEmpty                   as NE
import qualified Data.Map.Strict                      as Map
import           Data.Maybe                           (isNothing)
import qualified Data.Set                             as Set
import qualified Data.Text                            as T
import           Database.SQLite.Simple               (Connection, withConnection)
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

import qualified Data.ByteString.Lazy                 as BL
import           S3Up
import           S3Up.DB
import           S3Up.Effects
import           S3Up.Logging
import           S3Up.Types
import qualified System.Directory                     as Dir
import qualified System.Posix.Files                   as Posix

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

type S3Up es = ([IOE, S3Op, OptFX, FSFX, DBFX, LogFX, Error ETooBig] :>> es)

runS3FXIO :: IOE :> es => Eff (S3FX : es) a -> Eff es a
runS3FXIO = interpretIO \case
  InAWSFX a         -> newEnv discover >>= runResourceT . a
  InAWSRegionFX r a -> (newEnv discover <&> set #region r) >>= runResourceT . a

runS3Op :: S3FX :> es => Options -> Eff (S3Op : es) a -> Eff es a
runS3Op Options{..} = interpret \case
  ListBuckets -> toListOf (#buckets . folded . folded . #name) <$> inAWS (`send` S3.newListBuckets)
  ListMultipartUploads b -> toListOf (#uploads . folded . folded) <$> (inAWSBucket b . flip send) (S3.newListMultipartUploads b)
  CreateMultipartUpload k -> view #uploadId <$> inAWSBucket optBucket (flip send $ S3.newCreateMultipartUpload optBucket k & #storageClass ?~ optClass)
  NewUploadPart b i n c d -> view #eTag <$> inAWSBucket b (flip send $ S3.newUploadPart b i n c d)
  CompleteMultipartUpload b k i completed -> void <$> inAWSBucket b . flip send $ S3.newCompleteMultipartUpload b k i & #multipartUpload ?~ completed
  AbortMultipartUpload b k u -> void <$> inAWSBucket b $ flip send $ S3.newAbortMultipartUpload optBucket k u

runOptFX :: IOE :> es => Options -> Eff (OptFX : es) a -> Eff es a
runOptFX o = interpret \case
  GetOptionsFX -> pure o

runFSFX :: IOE :> es => Eff (FSFX : es) a -> Eff es a
runFSFX = interpretIO \case
  FileSize fp          -> toInteger . Posix.fileSize <$> (liftIO . Posix.getFileStatus) fp
  RemoveFile fp        -> liftIO (Dir.removeFile fp)
  FileChunk fp off len -> BL.take (fromIntegral len) <$> BL.drop (fromIntegral off) <$> BL.readFile fp

runFX :: (IOE :> es, Show err) => Connection -> Options -> Eff (LogFX : S3Op : S3FX : OptFX : FSFX : DBFX : Error err : es) a -> Eff es (Either err a)
runFX db o@Options{..} = runError . runDBFX db . runFSFX . runOptFX o . runS3FXIO . runS3Op o . runLogFX optVerbose

runCreate :: S3Up es => Either String (NonEmpty (FilePath, ObjectKey)) -> Eff es ()
runCreate (Left e) = logErrorL ["Invalid paths for create: ", T.pack e]
runCreate (Right xs) = do
  bn <- optBucket <$> getOptionsFX
  inflight <- Set.fromList . fmap (\(_,b,k) -> (b,k)) <$> listQueuedFiles
  let (doing, todo) = partition (\(_,k) -> (bn,k) `Set.member` inflight) (NE.toList xs)
  traverse_ (\(fp,ok) -> logInfoL ["Skipping in-flight upload of ", tshow fp, " -> ", tshow ok]) doing
  c <- optCreateConcurrency <$> getOptionsFX
  hook <- optHook <$> getOptionsFX
  mapConcurrentlyLimited_ c (one hook) todo

  where
    one hook (filename, key) = do
      PartialUpload{..} <- createMultipart hook filename key
      logDbgL ["Created upload for ", tshow _pu_bucket, ":", tshow _pu_key, " in ",
               tshow (length _pu_parts), " parts as ", _pu_upid]
      logInfo "Upload created.  Use the 'upload' command to complete."

runUpload :: S3Up es => Eff es ()
runUpload = do
  todo <- listPartialUploads
  unless (null todo) $ logInfoL [tshow (length todo), " files to upload for a total of about ",
                                 tshow (todoMB todo), " MB"]
  mapM_ completeUpload todo
  where todoMB = sum . fmap (\PartialUpload{..}
                             -> mb $ _pu_chunkSize * (toInteger . length . filter (isNothing . snd) $ _pu_parts))
        mb = (`div` (1024*1024))

runList :: S3Up es => Eff es ()
runList = do
  local <- Map.fromList . fmap (\pu@PartialUpload{..} -> ((_pu_bucket, _pu_upid), pu)) <$> listPartialUploads
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

runInteractiveAbort :: S3Up es => Eff es ()
runInteractiveAbort = do
  b <- getsOption optBucket
  items <- listMultiparts b
  mapM_ (askAbort b) items
  when (null items) $ logInfoL ["No multipart uploads to abort in ", tshow b]
  where
    askAbort b (t,k,i) = do
      liftIO . putStrLn $ fold [show t, " ", show k]
      shouldAbort <- prompt "delete? (y/N) "
      liftIO (putStrLn "")
      when shouldAbort $ logInfoL ["Deleting ", tshow i] >> abortUpload b k i

run :: S3Up es => Command -> Eff es ()
run (Create l)       = runCreate l
run Upload           = runUpload
run List             = runList
run (Abort o i)      = getsOption optBucket >>= \b -> abortUpload b o i
run InteractiveAbort = runInteractiveAbort

main :: IO ()
main = do
  confdir <- (</> ".config/s3up") <$> getHomeDirectory
  createDirectoryIfMissing True confdir
  o@Options{..} <- customExecParser (prefs showHelpOnError) (opts confdir)
  withConnection optDBPath $ \db ->
    runIOE (runFX db o (run optCommand)) >>= \case
      Left e  -> putStrLn ("Error: " <> show @ETooBig e)
      Right _ -> pure ()

  where
    opts confdir = info (options confdir <**> helper)
                ( fullDesc <> progDesc "S3 Upload utility.")
