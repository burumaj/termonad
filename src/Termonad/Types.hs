
module Termonad.Types where

import Termonad.Prelude

import Data.Unique (Unique, newUnique)
import GI.Gtk
  ( Application
  , ApplicationWindow(ApplicationWindow)
  , Box(Box)
  , CssProvider(CssProvider)
  , Dialog(Dialog)
  , Notebook(Notebook)
  , ScrolledWindow(ScrolledWindow)
  , pattern STYLE_PROVIDER_PRIORITY_APPLICATION
  , applicationNew
  , applicationSetAccelsForAction
  , builderNewFromString
  , builderSetApplication
  , noWidget
  , styleContextAddProviderForScreen
  )
import GI.Pango
  ( FontDescription
  , pattern SCALE
  , fontDescriptionNew
  , fontDescriptionSetFamily
  , fontDescriptionSetSize
  )
import GI.Vte (Terminal(Terminal))

import Termonad.FocusList

data TMTerm = TMTerm
  { term :: Terminal
  , unique :: Unique
  }

data TMNotebookTab = TMNotebookTab
  { tmNotebookTabTermContainer :: ScrolledWindow
  , tmNotebookTabTerm :: TMTerm
  }

data TMNotebook = TMNotebook
  { tmNotebook :: !Notebook
  , tmNotebookTabs :: !(FocusList TMNotebookTab)
  }

data TMState' = TMState
  { tmStateApp :: !Application
  , tmStateAppWin :: !ApplicationWindow
  , tmStateNotebook :: !TMNotebook
  , tmStateFontDesc :: !FontDescription
  }

type TMState = MVar TMState'

instance Eq TMTerm where
  (==) :: TMTerm -> TMTerm -> Bool
  (==) = (==) `on` (unique :: TMTerm -> Unique)

createTMTerm :: Terminal -> Unique -> TMTerm
createTMTerm trm unq =
  TMTerm
    { term = trm
    , unique = unq
    }

newTMTerm :: Terminal -> IO TMTerm
newTMTerm trm = do
  unq <- newUnique
  pure $ createTMTerm trm unq

createTMNotebookTab :: ScrolledWindow -> TMTerm -> TMNotebookTab
createTMNotebookTab scrollWin trm =
  TMNotebookTab
    { tmNotebookTabTermContainer = scrollWin
    , tmNotebookTabTerm = trm
    }

createTMNotebook :: Notebook -> FocusList TMNotebookTab -> TMNotebook
createTMNotebook note tabs =
  TMNotebook
    { tmNotebook = note
    , tmNotebookTabs = tabs
    }

newTMState :: Application -> ApplicationWindow -> TMNotebook -> FontDescription -> IO TMState
newTMState app appWin note fontDesc =
  newMVar $
    TMState
      { tmStateApp = app
      , tmStateAppWin = appWin
      , tmStateNotebook = note
      , tmStateFontDesc = fontDesc
      }

newTMStateSingleTerm ::
     Application
  -> ApplicationWindow
  -> Notebook
  -> ScrolledWindow
  -> Terminal
  -> FontDescription
  -> IO TMState
newTMStateSingleTerm app appWin note scrollWin trm fontDesc = do
  tmTerm <- newTMTerm trm
  let tmNoteTab = createTMNotebookTab scrollWin tmTerm
      tabs = singletonFL tmNoteTab
      tmNote = createTMNotebook note tabs
  newTMState app appWin tmNote fontDesc
