{-# LANGUAGE TypeApplications #-}

module Spec where

import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.QuickCheck as QC

import           S3Up

unit_MkObjectKey :: Assertion
unit_MkObjectKey = do
  assertEqual "full path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/file.txt")
  assertEqual "partial path" "tmp/file.txt" (mkObjectKey "/some/file.txt" "tmp/")

prop_minSize :: Positive (Large Int) -> Property
prop_minSize (Positive (Large fsize)) =
  counterexample ("Calculated chunk size: " <> show chunkSize
                  <> " with " <> show numChunks <> " chunks") $
    property $ numChunks <= 10000

  where
    chunkSize = calcMinSize fsize
    numChunks = ceiling @Double (fromIntegral fsize / fromIntegral chunkSize)
