module DBSpec where

import           Control.Monad.Reader   (ReaderT (..))
import           Data.List              (sort)
import           Data.Maybe             (listToMaybe)
import           Data.String
import           Database.SQLite.Simple
import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck  as QC
import Data.Foldable (traverse_)

import           S3Up.DB
import           S3Up.Types

instance Arbitrary PartialUpload where
  arbitrary = PartialUpload
                <$> chooseInt (1, 10000)
                <*> chooseInteger (20000, 2000000)
                <*> (fromString . getASCIIString <$> arbitrary)
                <*> (getASCIIString <$> arbitrary)
                <*> (fromString . getASCIIString <$> arbitrary)
                <*> (fromString . getASCIIString <$> arbitrary)
                <*> arbitraryBoundedEnum
                <*> (zip [0..] <$> listOf (Just . fromString . getASCIIString <$> arbitrary `suchThat` (not . null . getASCIIString)))

runDB :: ReaderT Connection IO a -> IO a
runDB a = withConnection ":memory:" $ \db -> do
  initTables db
  initTables db -- run this twice since in real life it'll run every time
  withDB db a

prop_storeUpload :: PartialUpload -> Property
prop_storeUpload pu = ioProperty $ do
  (nid, partial) <- runDB $ do
    nid <- _pu_id <$> storeUpload pu
    got <- maybe (fail "no results") pure . listToMaybe =<< listPartialUploads
    pure (nid, got{_pu_parts=sort (_pu_parts got)})
  -- The newly inserted ID gets stored and all the etags are eaten before insertion
  pure (pu{_pu_id=nid, _pu_parts=(fmap.fmap) (const Nothing) (_pu_parts pu)} === partial)

newtype CompletionLevel = CompletionLevel Double deriving Show

instance Arbitrary CompletionLevel where
  arbitrary = CompletionLevel <$> choose (0, 1)

prop_abortUpload :: PartialUpload -> CompletionLevel -> Property
prop_abortUpload pu (CompletionLevel cl) = ioProperty $ do
  partial <- runDB $ do
    nid <- _pu_id <$> storeUpload pu
    let todo = take (round (cl * (fromIntegral . length . _pu_parts $ pu))) (_pu_parts pu)
    traverse_ (\(i,_) -> completedUploadPart nid i "etag") todo
    abortedUpload (_pu_upid pu)
    listToMaybe <$> listPartialUploads
  pure (Nothing === partial)

prop_completeUpload :: PartialUpload -> CompletionLevel -> Property
prop_completeUpload pu (CompletionLevel cl) = ioProperty $ do
  partial <- runDB $ do
    nid <- _pu_id <$> storeUpload pu
    traverse_ (\(i,_) -> completedUploadPart nid i "etag") (_pu_parts pu)
    completedUpload nid
    listToMaybe <$> listPartialUploads
  pure (Nothing === partial)

prop_listFiles :: [PartialUpload] -> Property
prop_listFiles pups = ioProperty $ do
  files <- runDB (traverse_ storeUpload pups *> listQueuedFiles)
  pure (sort files === sort [_pu_filename p | p <- pups])
