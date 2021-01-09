module TidalHint where

import           Control.Exception
import           Control.Monad.Zip
import           Language.Haskell.Interpreter as Hint
import           Sound.Tidal.Context
import           System.IO
import           System.Posix.Signals
import           Control.Concurrent.MVar
import           Data.List (intercalate,isPrefixOf)
import           Sound.Tidal.Utils
import           Parameters

data Response = HintOK {parsed :: ControlPattern}
              | HintError {errorMessage :: String}

instance Show Response where
  show (HintOK p)    = "Ok: " ++ show p
  show (HintError s) = "Error: " ++ s

{-
runJob :: String -> IO (Response)
runJob job = do putStrLn $ "Parsing: " ++ job
                result <- hintControlPattern job
                let response = case result of
                      Left err -> Error (show err)
                      Right p -> OK p
                return response
-}

libs = ["Prelude","Sound.Tidal.Context","Sound.OSC.Datum",
        "Sound.Tidal.Simple", "Data.Map"
       ]

{-
hintControlPattern  :: String -> IO (Either InterpreterError ControlPattern)
hintControlPattern s = Hint.runInterpreter $ do
  Hint.set [languageExtensions := [OverloadedStrings]]
  Hint.setImports libs
  Hint.interpret s (Hint.as :: ControlPattern)
-}

hintJob :: (MVar String, MVar Response) -> [PScript] -> IO ()
hintJob (mIn, mOut) scripts =
  do result <- catch (do Hint.runInterpreter $ do
                           Hint.set [languageExtensions := [OverloadedStrings]]
                           Hint.setImportsQ (Prelude.map (\x -> (x, Nothing)) libs)
                           -- TODO: how to catch readfile errors?
                           liftIO $ hPutStrLn stderr ("pronto a leggere il file " ++ head scripts)
                           source <- liftIO $ readFile (head scripts)
                           liftIO $ hPutStrLn stderr ("file letto " ++ source)
                           runStmt source
                           hintLoop
                     )
               (\e -> return (Left $ UnknownError $ "exception" ++ show (e :: SomeException)))

     takeMVar mIn
     putMVar mOut (toResponse result)
     hintJob (mIn, mOut) scripts
     where hintLoop = do s <- liftIO (readMVar mIn)
                         let munged = deltaMini s
                         t <- Hint.typeChecksWithDetails munged
                         -- liftIO $ hPutStrLn stderr $ "munged: " ++ munged
                         --interp check s
                         interp t munged
                         hintLoop
           interp (Left errors) _ = do liftIO $ do putMVar mOut $ HintError $ "Didn't typecheck" ++ (concatMap show errors)
                                                   hPutStrLn stderr $ "error: " ++ (concatMap show errors)
                                                   takeMVar mIn
                                       return ()
           interp (Right t) s =
             do -- liftIO $ hPutStrLn stderr $ "type: " ++ t
                p <- Hint.interpret s (Hint.as :: ControlPattern)
                -- liftIO $ hPutStrLn stderr $ "first arc: " ++ (show p)
                liftIO $ putMVar mOut $ HintOK p
                liftIO $ takeMVar mIn
                return ()

toResponse :: Either InterpreterError ControlPattern -> Response
toResponse (Left err) = HintError (parseError err)
toResponse (Right p) = HintOK p

parseError :: InterpreterError -> String
parseError (UnknownError s) = "Unknown error: " ++ s
parseError (WontCompile es) = "Compile error: " ++ (intercalate "\n" (Prelude.map errMsg es))
parseError (NotAllowed s) = "NotAllowed error: " ++ s
parseError (GhcException s) = "GHC Exception: " ++ s
--parseError _ = "Strange error"