{-# LANGUAGE BlockArguments       #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

module DBSpec where

import           Cleff
import           Cleff.Fail
import           Data.Foldable          (traverse_)
import           Data.List              (sort)
import           Data.Maybe             (listToMaybe)
import           Data.String
import           Database.SQLite.Simple
import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck  as QC

import           S3Up.DB
import           S3Up.Effects
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

runDB :: forall a. (forall es. [DBFX, Fail, IOE] :>> es => Eff es a) -> IO a
runDB a = withConnection ":memory:" $ \db ->
  runIOE . runFailIO . runDBFX db $ do
    initTables
    initTables
    a

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
  pure (sort files === sort [(_pu_filename p, _pu_bucket p, _pu_key p) | p <- pups])
