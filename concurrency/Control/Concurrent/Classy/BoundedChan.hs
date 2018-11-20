--------------------------------------------------------------------------------

-- Copyright © 2009, Galois, Inc.
-- Copyright © 2018, DFINITY Stiftung
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
--
--   * Redistributions of source code must retain the above copyright
--     notice, this list of conditions and the following disclaimer.
--   * Redistributions in binary form must reproduce the above copyright
--     notice, this list of conditions and the following disclaimer in
--     the documentation and/or other materials provided with the
--     distribution.
--   * Neither the name of the Galois, Inc. nor the names of its
--     contributors may be used to endorse or promote products derived
--     from this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
-- "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
-- LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
-- FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
-- COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
-- INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
-- BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
-- CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
-- ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

--------------------------------------------------------------------------------

-- |
-- Module     : Control.Concurrent.Classy.BoundedChan
-- Copyright  : © 2009 Galois Inc.
--            , © 2018 DFINITY Stiftung
-- Maintainer : DFINITY USA Research <team@dfinity.org>
--
-- Implements bounded channels. These channels differ from normal 'Chan's in
-- that they are guaranteed to contain no more than a certain number of
-- elements. This is ideal when you may be writing to a channel faster than
-- you are able to read from it.
--
-- This module supports all the functions of "Control.Concurrent.Chan" except
-- 'unGetChan' and 'dupChan', which are not supported for bounded channels.
--
-- Extra consistency: This version enforces that if thread Alice writes
-- e1 followed by e2 then e1 will be returned by readBoundedChan before e2.
-- Conversely, if thead Bob reads e1 followed by e2 then it was true that
-- writeBoundedChan e1 preceded writeBoundedChan e2.
--
-- Previous versions did not enforce this consistency: if writeBoundedChan were
-- preempted between putMVars or killThread arrived between putMVars then it
-- can fail.  Similarly it might fail if readBoundedChan were stopped after putMVar
-- and before the second takeMVar.  An unlucky pattern of several such deaths
-- might actually break the invariants of the array in an unrecoverable way
-- causing all future reads and writes to block.

--------------------------------------------------------------------------------

module Control.Concurrent.Classy.BoundedChan
  ( BoundedChan
  , newBoundedChan
  , writeBoundedChan
  , trywriteBoundedChan
  , readBoundedChan
  , tryreadBoundedChan
  , isEmptyBoundedChan
  , writeList2BoundedChan
  ) where

--------------------------------------------------------------------------------

import           Control.Monad                  (replicateM)
import           Data.Array                     (Array, (!), listArray)

import           Control.Monad.Catch            (mask_, onException)
import           Control.Monad.Conc.Class       (MonadConc (MVar))
import qualified Control.Concurrent.Classy.MVar as MVar

--------------------------------------------------------------------------------

-- | A 'BoundedChan' is an abstract data type representing a bounded channel.
data BoundedChan m a
  = BoundedChan
    { _size     :: Int
    , _contents :: Array Int (MVar m a)
    , _writePos :: MVar m Int
    , _readPos  :: MVar m Int
    }
  deriving ()

-- TODO: check if the fields of BoundedChan could be strict / unpacked

--------------------------------------------------------------------------------

-- Versions of modifyMVar and withMVar that do not 'restore' the previous mask
-- state when running 'io', with added modification strictness.
-- The lack of 'restore' may make these perform better than the normal version.
-- Moving strictness here makes using them more pleasant.

{-# INLINE modifyMVar_mask #-}
modifyMVar_mask :: (MonadConc m) => MVar m a -> (a -> m (a, b)) -> m b
modifyMVar_mask m callback = mask_ $ do
  a <- MVar.takeMVar m
  (a', b) <- callback a `onException` MVar.putMVar m a
  MVar.putMVar m $! a'
  pure b

{-# INLINE modifyMVar_mask_ #-}
modifyMVar_mask_ :: (MonadConc m) => MVar m a -> (a -> m a) -> m ()
modifyMVar_mask_ m callback = do
  mask_ $ do
    a <- MVar.takeMVar m
    a' <- callback a `onException` MVar.putMVar m a
    MVar.putMVar m $! a'

{-# INLINE withMVar_mask #-}
withMVar_mask :: (MonadConc m) => MVar m a -> (a -> m b) -> m b
withMVar_mask m callback = do
  mask_ $ do
    a <- MVar.takeMVar m
    b <- callback a `onException` MVar.putMVar m a
    MVar.putMVar m a
    pure b

--------------------------------------------------------------------------------

-- |
-- @newBoundedChan n@ returns a channel than can contain no more than @n@
-- elements.
newBoundedChan :: (MonadConc m) => Int -> m (BoundedChan m a)
newBoundedChan x = do
  entls <- replicateM x MVar.newEmptyMVar
  wpos  <- MVar.newMVar 0
  rpos  <- MVar.newMVar 0
  let entries = listArray (0, x - 1) entls
  return (BoundedChan x entries wpos rpos)

-- |
-- Write an element to the channel. If the channel is full, this routine will
-- block until it is able to write. Blockers wait in a fair FIFO queue.
writeBoundedChan :: (MonadConc m) => BoundedChan m a -> a -> m ()
writeBoundedChan (BoundedChan size contents wposMV _) x = do
  modifyMVar_mask_ wposMV $ \wpos -> do
    MVar.putMVar (contents ! wpos) x
    pure ((succ wpos) `mod` size) -- only advance when putMVar succeeds

-- |
-- A variant of 'writeBoundedChan' which, instead of blocking when the channel is
-- full, simply aborts and does not write the element. Note that this routine
-- can still block while waiting for write access to the channel.
trywriteBoundedChan :: (MonadConc m) => BoundedChan m a -> a -> m Bool
trywriteBoundedChan (BoundedChan size contents wposMV _) x = do
  modifyMVar_mask wposMV $ \wpos -> do
    success <- MVar.tryPutMVar (contents ! wpos) x
    -- only advance when putMVar succeeds
    let wpos' = if success then succ wpos `mod` size else wpos
    pure (wpos', success)

-- |
-- Read an element from the channel. If the channel is empty, this routine
-- will block until it is able to read. Blockers wait in a fair FIFO queue.
readBoundedChan :: (MonadConc m) => BoundedChan m a -> m a
readBoundedChan (BoundedChan size contents _ rposMV) = do
  modifyMVar_mask rposMV $ \rpos -> do
    a <- MVar.takeMVar (contents ! rpos)
    pure (succ rpos `mod` size, a) -- only advance when takeMVar succeeds

-- |
-- A variant of 'readBoundedChan' which, instead of blocking when the channel is
-- empty, immediately returns 'Nothing'. Otherwise, 'tryreadBoundedChan' returns
-- @'Just' a@ where @a@ is the element read from the channel. Note that this
-- routine can still block while waiting for read access to the channel.
tryreadBoundedChan :: (MonadConc m) => BoundedChan m a -> m (Maybe a)
tryreadBoundedChan (BoundedChan size contents _ rposMV) = do
  modifyMVar_mask rposMV $ \rpos -> do
    ma <- MVar.tryTakeMVar (contents ! rpos)
    -- only advance when takeMVar succeeds
    let rpos' = case ma of
                  Just _  -> succ rpos `mod` size
                  Nothing -> rpos
    pure (rpos', ma)

-- |
-- Returns 'True' if the supplied channel is empty.
--
-- NOTE: This may block on an empty channel if there is a blocked reader.
-- NOTE: This function is deprecated.
{-# DEPRECATED isEmptyBoundedChan
               "This isEmptyBoundedChan can block, no non-blocking substitute yet" #-}
isEmptyBoundedChan :: (MonadConc m) => BoundedChan m a -> m Bool
isEmptyBoundedChan (BoundedChan _ contents _ rposMV) = do
  withMVar_mask rposMV $ \rpos -> do
    MVar.isEmptyMVar (contents ! rpos)

-- |
-- Write a list of elements to the channel.
-- If the channel becomes full, this routine will block until it can write.
-- Competing writers may interleave with this one.
writeList2BoundedChan :: (MonadConc m) => BoundedChan m a -> [a] -> m ()
writeList2BoundedChan = mapM_ . writeBoundedChan

--------------------------------------------------------------------------------