{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TemplateHaskell       #-}

-- | Storage with node local state which should be persistent.

module Pos.State.Storage
       (
         Storage

       , Query
       , getBlock
       , getHeadBlock
       , getLeaders
       , mayBlockBeUseful

       , ProcessBlockRes (..)

       , Update
       , processBlock
       , processNewSlot
       , processCommitment
       , processOpening
       , processShares
       , processTx
       , processVssCertificate
       ) where

import           Control.Lens            (makeClassy, use, (.=))
import           Data.Acid               ()
import           Data.Default            (Default, def)
import           Data.SafeCopy           (base, deriveSafeCopySimple)
import           Serokell.AcidState      ()
import           Serokell.Util           (VerificationRes (..))
import           Universum

import           Pos.Crypto              (PublicKey, Share)
import           Pos.State.Storage.Block (BlockStorage, HasBlockStorage (blockStorage),
                                          blkCleanUp, blkProcessBlock, blkRollback,
                                          blkSetHead, getBlock, getHeadBlock, getLeaders,
                                          mayBlockBeUseful)
import           Pos.State.Storage.Mpc   (HasMpcStorage (mpcStorage), MpcStorage,
                                          mpcApplyBlocks, mpcProcessCommitment,
                                          mpcProcessOpening, mpcProcessShares,
                                          mpcProcessVssCertificate, mpcRollback,
                                          mpcVerifyBlock, mpcVerifyBlocks)
import           Pos.State.Storage.Tx    (HasTxStorage (txStorage), TxStorage, processTx)
import           Pos.State.Storage.Types (AltChain, ProcessBlockRes (..), mkPBRabort)
import           Pos.Types               (Block, Commitment, CommitmentSignature, Opening,
                                          SlotId, VssCertificate, unflattenSlotId)
import           Pos.Util                (readerToState)

type Query  a = forall m . MonadReader Storage m => m a
type Update a = forall m . MonadState Storage m => m a

data Storage = Storage
    { -- | State of MPC.
      __mpcStorage   :: !MpcStorage
    , -- | Transactions part of /static-state/.
      __txStorage    :: !TxStorage
    , -- | Blockchain part of /static-state/.
      __blockStorage :: !BlockStorage
    , -- | Id of last seen slot.
      _slotId        :: !SlotId
    }

makeClassy ''Storage
deriveSafeCopySimple 0 'base ''Storage

instance HasMpcStorage Storage where
    mpcStorage = _mpcStorage
instance HasTxStorage Storage where
    txStorage = _txStorage
instance HasBlockStorage Storage where
    blockStorage = _blockStorage

instance Default Storage where
    def =
        Storage
        { __mpcStorage = def
        , __txStorage = def
        , __blockStorage = def
        , _slotId = unflattenSlotId 0
        }

-- | Do all necessary changes when a block is received.
processBlock :: SlotId -> Block -> Update ProcessBlockRes
processBlock curSlotId blk = do
    mpcRes <- readerToState $ mpcVerifyBlock blk
    txRes <- pure mempty
    case mpcRes <> txRes of
        VerSuccess        -> processBlockDo curSlotId blk
        VerFailure errors -> return $ mkPBRabort errors

processBlockDo :: SlotId -> Block -> Update ProcessBlockRes
processBlockDo curSlotId blk = do
    r <- blkProcessBlock curSlotId blk
    case r of
        PBRgood (toRollback, chain) -> do
            mpcRes <- readerToState $ mpcVerifyBlocks toRollback chain
            txRes <- pure mempty
            case mpcRes <> txRes of
                VerSuccess        -> processBlockFinally toRollback chain
                VerFailure errors -> return $ mkPBRabort errors
        _ -> return r

processBlockFinally :: Word -> AltChain -> Update ProcessBlockRes
processBlockFinally toRollback blocks = do
    mpcRollback toRollback
    mpcApplyBlocks blocks
    blkRollback toRollback
    blkSetHead undefined
    -- txFoo
    -- txBar
    return $ PBRgood (toRollback, blocks)

-- | Do all necessary changes when new slot starts.
processNewSlot :: SlotId -> Update ()
processNewSlot sId = do
    knownSlot <- use slotId
    when (sId > knownSlot) $ processNewSlotDo sId

-- TODO
processNewSlotDo :: SlotId -> Update ()
processNewSlotDo sId = do
    slotId .= sId
    blkCleanUp sId

processCommitment :: PublicKey -> (Commitment, CommitmentSignature) -> Update ()
processCommitment = mpcProcessCommitment

processOpening :: PublicKey -> Opening -> Update ()
processOpening = mpcProcessOpening

processShares :: PublicKey -> HashMap PublicKey Share -> Update ()
processShares = mpcProcessShares

processVssCertificate :: PublicKey -> VssCertificate -> Update ()
processVssCertificate = mpcProcessVssCertificate
