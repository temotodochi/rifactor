{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- Module      : Main
-- Copyright   : (c) 2015 Knewton, Inc <se@knewton.com>
--               (c) 2015 Tim Dysinger <tim@dysinger.net> (contributor)
-- License     : Apache 2.0 http://opensource.org/licenses/Apache-2.0
-- Maintainer  : Tim Dysinger <tim@dysinger.net>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

import           BasePrelude
import           Control.Lens
import           Control.Monad.Trans.AWS (Env, envRegion)
import           Data.Time (UTCTime, getCurrentTime)
import qualified Data.Text as T
import           Network.AWS.EC2
import           Rifactor.Plan
import           Rifactor.Types
import           Test.Tasty
import           Test.Tasty.Hspec

main :: IO ()
main = tests >>= defaultMain

tests :: IO TestTree
tests =
  sequence [matchSpec,moveSpec,splitSpec,combineSpec,resizeSpec] >>=
  pure .
  testGroup "Tests"

matchSpec :: IO TestTree
matchSpec =
  testSpec "Matching" $
  describe "ReservedInstances With Instances" $
  context "with 20 reserved (m2.4xlarge/us-east-1a)" $
  do context "and 20 instances (m2.4xlarge/us-east-1a)" $
       it "will match by type, network & AZ" $
       do reserved <-
            mkReserved 2 "us-east-1a" 10 M2_4XLarge
          onDemand <-
            mkInstances 20 "us-east-1a" M2_4XLarge
          let (r,rest) =
                matchReserved (reserved,onDemand)
          all isUsedReserved r `shouldBe`
            True
          rest `shouldBe` empty
     context "and 20 instances (m2.4xlarge/us-east-1b)" $
       it "will not match by instance type alone" $
       do reserved <-
            mkReserved 2 "us-east-1a" 10 M2_4XLarge
          onDemand <-
            mkInstances 20 "us-east-1b" M2_4XLarge
          let (r,rest) =
                matchReserved (reserved,onDemand)
          all isReserved r `shouldBe`
            True
          length rest `shouldBe` 20

moveSpec :: IO TestTree
moveSpec =
  testSpec "Moving" $
  describe "Ununused ReservedInstances" $
  context "with 20 reserved (m2.4xlarge/us-east-1a)" $
  context "and 20 instances (m2.4xlarge/us-east-1b)" $
  it "will match by instance type & move" $
  do reserved <-
       mkReserved 2 "us-east-1a" 10 M2_4XLarge
     onDemand <-
       mkInstances 20 "us-east-1b" M2_4XLarge
     let (r,rest) =
           moveReserved (reserved,onDemand)
     all isMoveReserved r `shouldBe`
       True
     traverse_ (\r' ->
                  length (r' ^. reNewInstances) `shouldBe`
                  10)
               r
     rest `shouldBe` empty

splitSpec :: IO TestTree
splitSpec =
  testSpec "Splitting" $
  describe "Used ReservedInstances (That Have Capacity)" $
  context "with 40 reserved m2.4xlarge/us-east-1a" $
  context "and 20 instances m2.4xlarge/us-east-1a" $
  context "and 20 instances m2.4xlarge/us-east-1b" $
  it "will match all instances & split" $
  do usedInstances <-
       mkInstances 20 "us-east-1a" M2_4XLarge
     usedReserved <-
       mkUsedReserved 1 "us-east-1a" 40 M2_4XLarge usedInstances
     wrongAzInstances <-
       mkInstances 20 "us-east-1b" M2_4XLarge
     let ((r:rest'),rest'') =
           splitReserved (usedReserved,wrongAzInstances)
     isSplitReserved r `shouldBe` True
     length (r ^. reInstances) `shouldBe`
       20
     length (r ^. reNewInstances) `shouldBe`
       20
     rest' `shouldBe` empty
     rest'' `shouldBe` empty

combineSpec :: IO TestTree
combineSpec =
  testSpec "Combining" $
  describe "ReservedInstances (That Are Not Being Modified)" $
  context "with 2 x 10 reserved m2.4xlarge/us-east-1a" $
  context "and 0 instances m2.4xlarge/us-east-1" $
  it "will combine reserved instances with same end date/hour" $
  do unusedReserved <-
       mkReserved 2 "us-east-1a" 10 M2_4XLarge
     let ((r:rest'),rest'') =
           combineReserved (unusedReserved,[])
     isCombineReserved r `shouldBe` True
     length (r ^. reReservedInstances') `shouldBe`
       2
     rest' `shouldBe` empty
     rest'' `shouldBe` empty

resizeSpec :: IO TestTree
resizeSpec =
  testSpec "Resizing" $
  describe "ReservedInstances (That Are No Longer Used)" $
  context "with 100 reserved m2.4xlarge/us-east-1a" $
  context "and 0 instances m2.4xlarge/us-east-1" $
  context "and 120 instances m2.2xlarge/us-east-1" $
  it "will resize reserved instances to match" $
  pending

mkUsedReserved :: Int -> String -> Int -> InstanceType -> [OnDemand] -> IO [Reserved]
mkUsedReserved rCount az iCount itype xs =
  do time <- getCurrentTime
     env <- noKeysEnv
     pure (map (\_ ->
                  UsedReserved env
                               (riFixture iCount az itype time)
                               (map (view odInstance) xs))
               ([1 .. rCount] :: [Int]))

mkReserved :: Int -> String -> Int -> InstanceType -> IO [Reserved]
mkReserved rCount az iCount itype =
  do time <- getCurrentTime
     env <- noKeysEnv
     pure (map (\_ ->
                  Reserved env (riFixture iCount az itype time))
               ([1 .. rCount] :: [Int]))

mkInstances :: Int -> String -> InstanceType -> IO [OnDemand]
mkInstances iCount az itype =
  do time <- getCurrentTime
     mapM (\instanceNum ->
             pure (OnDemand (iFixture az itype time (show instanceNum))))
          ([1 .. iCount] :: [Int])

riFixture :: Int -> String -> InstanceType -> UTCTime -> ReservedInstances
riFixture count az itype time =
  reservedInstances &
  (ri1AvailabilityZone ?~ T.pack az) &
  (ri1InstanceCount ?~ count) &
  (ri1InstanceType ?~ itype) &
  (ri1End ?~ time) &
  (ri1InstanceTenancy ?~ Dedicated)

iFixture :: String -> InstanceType -> UTCTime -> String -> Instance
iFixture az itype time iid =
  (instance' (T.pack iid)
             (T.pack "ami-fake0")
             (instanceState 16 ISNRunning)
             42
             itype
             time
             (placement &
              (pAvailabilityZone ?~ T.pack az))
             (monitoring &
              (mState ?~ MSDisabled))
             X8664
             InstanceStore
             Hvm
             Xen
             False)

instance Show Env where
  show e = show (e ^. envRegion)

instance Show Reserved where
  show = T.unpack . summary

instance Show OnDemand where
  show = T.unpack . summary
