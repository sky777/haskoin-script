module Haskoin.Script.Parser
( ScriptOutput(..)
, ScriptInput(..)
, RedeemScript
, ScriptHashInput(..)
, scriptAddr
, encodeInput
, decodeInput
, encodeOutput
, decodeOutput
, encodeScriptHash
, decodeScriptHash
, intToScriptOp
, scriptOpToInt
) where

import Control.Monad
import Control.Applicative

import Data.Bits
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as BS

import Haskoin.Script.SigHash
import Haskoin.Crypto
import Haskoin.Protocol
import Haskoin.Util

data ScriptOutput = 
      PayPK         { runPayPubKey      :: !PubKey }
    | PayPKHash     { runPayPubKeyHash  :: !Address }
    | PayMulSig     { payMulSigKeys     :: ![PubKey]
                    , payMulSigRequired :: !Int
                    }
    | PayScriptHash { runPayScriptHash  :: !Address }
    deriving (Eq, Show)

scriptAddr :: ScriptOutput -> Address
scriptAddr = ScriptAddress . hash160 . hash256BS . encode' . encodeOutput
    
encodeOutput :: ScriptOutput -> Script
encodeOutput s = Script $ case s of
    -- Pay to PubKey
    (PayPK k) -> [OP_PUSHDATA $ encode' k, OP_CHECKSIG]
    -- Pay to PubKey Hash Address
    (PayPKHash a) -> case a of
        (PubKeyAddress h) -> [ OP_DUP, OP_HASH160, OP_PUSHDATA $ encode' h
                             , OP_EQUALVERIFY, OP_CHECKSIG 
                             ] 
        (ScriptAddress _) -> 
            error "encodeOutput: ScriptAddress is invalid in PayPKHash"
    -- Pay to MultiSig Keys
    (PayMulSig ps r)
      | r <= length ps ->
        let opM = intToScriptOp r
            opN = intToScriptOp $ length ps
            keys = map (OP_PUSHDATA . encode') ps
            in opM : keys ++ [opN, OP_CHECKMULTISIG]
      | otherwise -> error "encodeOutput: PayMulSig r must be <= than pkeys"
    -- Pay to Script Hash Address
    (PayScriptHash a) -> case a of
        (ScriptAddress h) -> [ OP_HASH160
                             , OP_PUSHDATA $ encode' h, OP_EQUAL
                             ]
        (PubKeyAddress _) -> 
            error "encodeOutput: PubKeyAddress is invalid in PayScriptHash"

decodeOutput :: Script -> Either String ScriptOutput
decodeOutput s = case runScript s of
    -- Pay to PubKey
    [OP_PUSHDATA bs, OP_CHECKSIG] -> PayPK <$> decodeToEither bs
    -- Pay to PubKey Hash
    [OP_DUP, OP_HASH160, OP_PUSHDATA bs, OP_EQUALVERIFY, OP_CHECKSIG] -> 
        (PayPKHash . PubKeyAddress) <$> decodeToEither bs
    -- Pay to Script Hash
    [OP_HASH160, OP_PUSHDATA bs, OP_EQUAL] -> 
        (PayScriptHash . ScriptAddress) <$> decodeToEither bs
    -- Pay to MultiSig Keys
    _ -> matchPayMulSig s

-- Match [ OP_N, PubKey1, ..., PubKeyM, OP_M, OP_CHECKMULTISIG ]
matchPayMulSig :: Script -> Either String ScriptOutput
matchPayMulSig s@(Script ops) = case splitAt (length ops - 2) ops of
    (m:xs,[n,OP_CHECKMULTISIG]) -> do
        (intM,intN) <- liftM2 (,) (scriptOpToInt m) (scriptOpToInt n)
        if intM <= intN && length xs == intN 
            then liftM2 PayMulSig (go xs) (return intM)
            else Left "matchPayMulSig: Invalid M or N parameters"
    _ -> Left "matchPayMulSig: script did not match output template"
    where go (OP_PUSHDATA bs:xs) = liftM2 (:) (decodeToEither bs) (go xs)
          go [] = return []
          go  _ = Left "matchPayMulSig: invalid multisig opcode"

-- Decode OP_1 to OP_16
intToScriptOp :: Int -> ScriptOp
intToScriptOp i
    | i `elem` [1..16] = op
    |        otherwise = error $ "intToScriptOp: Invalid integer " ++ (show i)
    where op = decode' $ BS.singleton $ fromIntegral $ i + 0x50

-- Encode OP_1 to OP_16
scriptOpToInt :: ScriptOp -> Either String Int
scriptOpToInt s 
    | res `elem` [1..16] = return res
    | otherwise          = Left $ "scriptOpToInt: invalid opcode " ++ (show s)
    where res = (fromIntegral $ BS.head $ encode' s) - 0x50

data ScriptInput = 
      SpendPK     { runSpendPK        :: !TxSignature }
    | SpendPKHash { runSpendPKHashSig :: !TxSignature 
                  , runSpendPKHashKey :: !PubKey
                  }
    | SpendMulSig { runSpendMulSigs   :: ![TxSignature] 
                  , runRequiredSigs   :: !Int
                  }
    deriving (Eq, Show)

encodeInput :: ScriptInput -> Script
encodeInput s = Script $ case s of
    SpendPK ts        -> [ OP_PUSHDATA $ encodeSig ts ]
    SpendPKHash ts p  -> [ OP_PUSHDATA $ encodeSig ts
                         , OP_PUSHDATA $ encode' p
                         ]
    SpendMulSig ts r 
        | length ts <= 16 && r >= 1 && r <= 16 ->
            let sigs = map (OP_PUSHDATA . encodeSig) ts
                in OP_0 : sigs ++ replicate (r - length ts) OP_0
        | otherwise -> error "SpendMulSig: Bad multisig parameters"

decodeInput :: Script -> Either String ScriptInput
decodeInput s = case runScript s of
    [OP_PUSHDATA bs] -> SpendPK <$> decodeSig bs 
    [OP_PUSHDATA s, OP_PUSHDATA p] -> 
        liftM2 SpendPKHash (decodeSig s) (decodeToEither p)
    (OP_0 : xs) -> matchSpendMulSig $ Script xs
    _ -> Left "decodeInput: Script did not match input templates"

matchSpendMulSig :: Script -> Either String ScriptInput
matchSpendMulSig (Script ops) = 
    liftM2 SpendMulSig (go ops) (return $ length ops)
    where go (OP_PUSHDATA bs:xs) = liftM2 (:) (decodeSig bs) (go xs)
          go (OP_0:xs)
            | all (== OP_0) xs = return []
            | otherwise = Left "matchSpendMulSig: invalid opcode after OP_0"
          go [] = return []
          go _  = Left "matchSpendMulSig: invalid multisig opcode"

type RedeemScript = ScriptOutput

data ScriptHashInput = ScriptHashInput 
    { spendSHInput  :: ScriptInput 
    , spendSHOutput :: RedeemScript
    } deriving (Eq, Show)

encodeScriptHash :: ScriptHashInput -> Script
encodeScriptHash (ScriptHashInput i o) =
    Script $ si ++ [OP_PUSHDATA $ runPut' $ putScriptOps so]
    where (Script si) = encodeInput i
          (Script so) = encodeOutput o

decodeScriptHash :: Script -> Either String ScriptHashInput
decodeScriptHash (Script ops) = case splitAt (length ops - 1) ops of
    (is,[OP_PUSHDATA bs]) -> fromRunGet getScriptOps bs decodeErr $ \os ->
        ScriptHashInput <$> (decodeInput  $ Script is) 
                        <*> (decodeOutput $ Script os)
    _ -> Left "decodeScriptHash: Script did not match input template"
    where decodeErr = Left "decodeScriptHash: could not decode redeem script"

