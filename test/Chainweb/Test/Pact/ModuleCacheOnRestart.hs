{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

module Chainweb.Test.Pact.ModuleCacheOnRestart (tests) where

import Control.Concurrent.MVar.Strict
import Control.DeepSeq (NFData)
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

import Data.CAS.RocksDB
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as M
import Data.List (intercalate)
import qualified Data.Text.IO as T

import GHC.Generics

import Test.Tasty.HUnit
import Test.Tasty

import System.LogLevel

-- pact imports

import Pact.Types.Runtime (mdModule)
import Pact.Types.Term

-- chainweb imports

import Chainweb.BlockHeader
import Chainweb.BlockHeader.Genesis
import Chainweb.ChainId
import Chainweb.Logger
import Chainweb.Miner.Pact
import Chainweb.Pact.Backend.Types
import Chainweb.Pact.PactService
import Chainweb.Pact.Types
import Chainweb.Payload
import Chainweb.Payload.PayloadStore
import Chainweb.Time
import Chainweb.Test.Cut
import Chainweb.Test.Cut.TestBlockDb
import Chainweb.Test.Utils
import Chainweb.Test.Pact.Utils
import Chainweb.Utils (T2(..))
import Chainweb.Version
import Chainweb.WebBlockHeaderDB

testVer :: ChainwebVersion
testVer = FastTimedCPM singleton

testChainId :: ChainId
testChainId = unsafeChainId 0

type RewindPoint = (BlockHeader, PayloadWithOutputs)

data RewindData = RewindData
  { afterV4 :: RewindPoint
  , beforeV4 :: RewindPoint
  , v3Cache :: HM.HashMap ModuleName (Maybe ModuleHash)
  } deriving Generic

instance NFData RewindData

tests :: RocksDb -> ScheduledTest
tests rdb =
      ScheduledTest label $
      withMVarResource mempty $ \iom ->
      withEmptyMVarResource $ \rewindDataM ->
      withTestBlockDbTest testVer rdb $ \bdbio ->
      withTempSQLiteResource $ \ioSqlEnv ->
      testGroup label
      [ testCase "testInitial" $ withPact' bdbio ioSqlEnv iom testInitial
      , after AllSucceed "testInitial" $
        testCase "testRestart1" $ withPact' bdbio ioSqlEnv iom testRestart
      , after AllSucceed "testRestart1" $
        -- wow, Tasty thinks there's a "loop" if the following test is called "testCoinbase"!!
        testCase "testDoUpgrades" $ withPact' bdbio ioSqlEnv iom (testCoinbase bdbio)
      , after AllSucceed "testDoUpgrades" $
        testCase "testRestart2" $ withPact' bdbio ioSqlEnv iom testRestart
      , after AllSucceed "testRestart2" $
        testCase "testV3" $ withPact' bdbio ioSqlEnv iom (testV3 bdbio rewindDataM)
      , after AllSucceed "testV3" $
        testCase "testRestart3"$ withPact' bdbio ioSqlEnv iom testRestart
      , after AllSucceed "testRestart3" $
        testCase "testV4" $ withPact' bdbio ioSqlEnv iom (testV4 bdbio rewindDataM)
      , after AllSucceed "testV4" $
        testCase "testRestart4" $ withPact' bdbio ioSqlEnv iom testRestart
      , after AllSucceed "testRestart4" $
        testCase "testRewindAfterFork" $ withPact' bdbio ioSqlEnv iom (testRewindAfterFork bdbio rewindDataM)
      , after AllSucceed "testRewindAfterFork" $
        testCase "testRewindBeforeFork" $ withPact' bdbio ioSqlEnv iom (testRewindBeforeFork bdbio rewindDataM)
      , after AllSucceed "testRewindBeforeFork" $
        testCase "testCw217CoinOnly" $ withPact' bdbio ioSqlEnv iom $
          testCw217CoinOnly bdbio rewindDataM
      , after AllSucceed "testCw217CoinOnly" $
        testCase "testRestartCw217" $
        withPact' bdbio ioSqlEnv iom testRestart
      ]
  where
    label = "Chainweb.Test.Pact.ModuleCacheOnRestart"

type CacheTest cas =
  (PactServiceM cas ()
  ,IO (MVar ModuleInitCache) -> ModuleInitCache -> Assertion)

-- | Do genesis load, snapshot cache.
testInitial :: PayloadCasLookup cas => CacheTest cas
testInitial = (initPayloadState,snapshotCache)

-- | Do restart load, test results of 'initialPayloadState' against snapshotted cache.
testRestart :: PayloadCasLookup cas => CacheTest cas
testRestart = (initPayloadState,checkLoadedCache)
  where
    checkLoadedCache ioa initCache = do
      a <- ioa >>= readMVar
      (justModuleHashes a) `assertNoCacheMismatch` (justModuleHashes initCache)

-- | Run coinbase to do upgrade to v2, snapshot cache.
testCoinbase :: PayloadCasLookup cas => IO TestBlockDb -> CacheTest cas
testCoinbase iobdb = (initPayloadState >> doCoinbase,snapshotCache)
  where
    doCoinbase = do
      bdb <- liftIO $ iobdb
      pwo <- execNewBlock mempty (ParentHeader genblock) noMiner
      liftIO $ addTestBlockDb bdb (Nonce 0) (offsetBlockTime second) testChainId pwo
      nextH <- liftIO $ getParentTestBlockDb bdb testChainId
      void $ execValidateBlock mempty nextH (payloadWithOutputsToPayloadData pwo)

testV3 :: PayloadCasLookup cas => IO TestBlockDb -> IO (MVar RewindData) -> CacheTest cas
testV3 iobdb rewindM = (go,grabAndSnapshotCache)
  where
    go = do
      initPayloadState
      void $ doNextCoinbase iobdb
      void $ doNextCoinbase iobdb
      hpwo <- doNextCoinbase iobdb
      liftIO (rewindM >>= \rewind -> putMVar rewind $ RewindData hpwo hpwo mempty)
    grabAndSnapshotCache ioa initCache = do
      rewindM >>= \rewind -> modifyMVar_ rewind $ \old -> pure $ old { v3Cache = justModuleHashes initCache }
      snapshotCache ioa initCache



testV4 :: PayloadCasLookup cas => IO TestBlockDb -> IO (MVar RewindData) -> CacheTest cas
testV4 iobdb rewindM = (go,snapshotCache)
  where
    go = do
      initPayloadState
      -- at the upgrade/fork point
      void $ doNextCoinbase iobdb
      -- just after the upgrade/fork point
      afterV4' <- doNextCoinbase iobdb
      rewind <- liftIO rewindM
      liftIO $ modifyMVar_ rewind $ \old -> pure $ old { afterV4 = afterV4' }
      void $ doNextCoinbase iobdb
      void $ doNextCoinbase iobdb

testRewindAfterFork :: PayloadCasLookup cas => IO TestBlockDb -> IO (MVar RewindData) -> CacheTest cas
testRewindAfterFork iobdb rewindM = (go, checkLoadedCache)
  where
    go = do
      initPayloadState
      liftIO rewindM >>= liftIO . readMVar >>= rewindToBlock . afterV4
      void $ doNextCoinbase iobdb
      void $ doNextCoinbase iobdb
    checkLoadedCache ioa initCache = do
      a <- ioa >>= readMVar
      case M.lookup 6 initCache of
        Nothing -> assertFailure "Cache not found at height 6"
        Just c -> (justModuleHashes a) `assertNoCacheMismatch` (justModuleHashes' c)

testRewindBeforeFork :: PayloadCasLookup cas => IO TestBlockDb -> IO (MVar RewindData) -> CacheTest cas
testRewindBeforeFork iobdb rewindM = (go, checkLoadedCache)
  where
    go = do
      initPayloadState
      liftIO rewindM >>= liftIO . readMVar >>= rewindToBlock . beforeV4
      void $ doNextCoinbase iobdb
      void $ doNextCoinbase iobdb
    checkLoadedCache ioa initCache = do
      a <- ioa >>= readMVar
      case (M.lookup 5 initCache, M.lookup 4 initCache) of
        (Just c, Just d) -> do
          (justModuleHashes a) `assertNoCacheMismatch` (justModuleHashes' c)
          v3c <- rewindM >>= \rewind -> fmap v3Cache (readMVar rewind)
          assertNoCacheMismatch v3c (justModuleHashes' d)
        _ -> assertFailure "Failed to lookup either block 4 or 5."

testCw217CoinOnly
    :: PayloadCasLookup cas
    => IO TestBlockDb
    -> IO (MVar RewindData)
    -> CacheTest cas
testCw217CoinOnly iobdb _rewindM = (go, go')
  where
    go = do
      initPayloadState
      void $ doNextCoinbaseN_ 9 iobdb

    go' ioa initCache = do
      snapshotCache ioa initCache
      case M.lookup 20 initCache of
        Just a -> assertEqual "module init cache contains only coin" ["coin"] $ HM.keys a
        Nothing -> assertFailure "failed to lookup block at 20"

assertNoCacheMismatch
    :: HM.HashMap ModuleName (Maybe ModuleHash)
    -> HM.HashMap ModuleName (Maybe ModuleHash)
    -> Assertion
assertNoCacheMismatch c1 c2 = assertBool msg $ c1 == c2
  where
    showCache = intercalate "\n" . map show . HM.toList
    msg = mconcat
      [
      "Module cache mismatch, found: \n"
      , showCache c1
      , "\n expected: \n"
      , showCache c2
      ]

rewindToBlock :: PayloadCasLookup cas => RewindPoint -> PactServiceM cas ()
rewindToBlock (rewindHeader, pwo) = void $ execValidateBlock mempty rewindHeader (payloadWithOutputsToPayloadData pwo)

doNextCoinbase :: PayloadCasLookup cas => IO TestBlockDb -> PactServiceM cas (BlockHeader, PayloadWithOutputs)
doNextCoinbase iobdb = do
      bdb <- liftIO iobdb
      prevH <- liftIO $ getParentTestBlockDb bdb testChainId
      pwo <- execNewBlock mempty (ParentHeader prevH) noMiner
      liftIO $ addTestBlockDb bdb (Nonce 0) (offsetBlockTime second) testChainId pwo
      nextH <- liftIO $ getParentTestBlockDb bdb testChainId
      valPWO <- execValidateBlock mempty nextH (payloadWithOutputsToPayloadData pwo)
      return (nextH, valPWO)

doNextCoinbaseN_
    :: PayloadCasLookup cas
    => Int
    -> IO TestBlockDb
    -> PactServiceM cas (BlockHeader, PayloadWithOutputs)
doNextCoinbaseN_ n iobdb = fmap last $ forM [1..n] $ \_ ->
    doNextCoinbase iobdb

-- | Interfaces can't be upgraded, but modules can, so verify hash in that case.
justModuleHashes :: ModuleInitCache -> HM.HashMap ModuleName (Maybe ModuleHash)
justModuleHashes = justModuleHashes' . snd . last . M.toList

justModuleHashes' :: ModuleCache -> HM.HashMap ModuleName (Maybe ModuleHash)
justModuleHashes' = HM.map $ \v -> preview (_1 . mdModule . _MDModule . mHash) v

genblock :: BlockHeader
genblock = genesisBlockHeader testVer testChainId

initPayloadState :: PayloadCasLookup cas => PactServiceM cas ()
initPayloadState = initialPayloadState dummyLogger mempty testVer testChainId

snapshotCache :: IO (MVar ModuleInitCache) -> ModuleInitCache -> IO ()
snapshotCache iomcache initCache = do
  mcache <- iomcache
  modifyMVar_ mcache (const (pure initCache))

withPact'
    :: IO TestBlockDb
    -> IO SQLiteEnv
    -> IO (MVar ModuleInitCache)
    -> CacheTest RocksDbCas
    -> Assertion
withPact' bdbio ioSqlEnv r (ps, cacheTest) = do
    bdb <- bdbio
    bhdb <- getWebBlockHeaderDb (_bdbWebBlockHeaderDb bdb) testChainId
    let pdb = _bdbPayloadDb bdb
    sqlEnv <- ioSqlEnv
    T2 _ pstate <- initPactService'
        testVer testChainId logger bhdb pdb sqlEnv defaultPactServiceConfig ps
    cacheTest r (_psInitCache pstate)
  where
    logger = genericLogger Quiet T.putStrLn
