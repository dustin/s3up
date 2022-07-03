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
  withDB db a

prop_storeUpload :: PartialUpload -> Property
prop_storeUpload pu = ioProperty $ do
  (nid, partial) <- runDB $ do
    nid <- _pu_id <$> storeUpload pu
    got <- maybe (fail "no results") pure . listToMaybe =<< listPartialUploads
    pure (nid, got{_pu_parts=sort (_pu_parts got)})
  -- The newly inserted ID gets stored and all the etags are eaten before insertion
  pure (pu{_pu_id=nid, _pu_parts=(fmap.fmap) (const Nothing) (_pu_parts pu)} === partial)
