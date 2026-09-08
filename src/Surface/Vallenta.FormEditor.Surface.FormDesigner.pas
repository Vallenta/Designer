// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.FormDesigner;

// Designer surface for one loaded document: selection, input handling, grid,
// dirty tracking and the save/close flow. Implements IDesignerHook on the
// hook host form. Main thread only.
//
// Hook host and designed root differ: a form is both, a frame is designed on
// a chrome-only host form because the hook must sit on a form, and a data
// module has no window - its hook host is nil and input arrives from the icon
// canvas rather than from IsDesignMsg.

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.Types,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Graphics,
  DesignIntf,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Streaming.Clipboard,
  Vallenta.FormEditor.DesignTime.Designer,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.FieldLedger,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.Frames,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Palette.Model,
  Vallenta.FormEditor.Streaming.Preserved,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Surface.Handles,
  Vallenta.FormEditor.Surface.TileLayer,
  Vallenta.FormEditor.Surface.Undo;

type
  // Gesture state of the surface; each pending value becomes its real
  // counterpart once the cursor has moved DragThreshold pixels.
  TDragKind = (dkNone, dkPending, dkMove, dkResize, dkCreatePending, dkCreate,
    dkMarqueePending, dkMarquee);

  // Horizontal align action; ahLeft, ahCenters and ahRight take the primary
  // selection as reference.
  TAlignHorizontal = (ahNone, ahLeft, ahCenters, ahRight, ahSpaceEqually,
    ahCenterInWindow);
  // Vertical align action; avTop, avMiddles and avBottom take the primary
  // selection as reference.
  TAlignVertical = (avNone, avTop, avMiddles, avBottom, avSpaceEqually,
    avCenterInWindow);
  // Size-matching action; smFromPrimary copies the primary selection's extent.
  TSizeMatch = (smNone, smFromPrimary);

  // End of a parent's child order a z-order step moves a control to. The
  // front is the topmost control and the last one written to the form file.
  TZOrderStep = (zsToFront, zsToBack);

  // How a placed palette item gets its bounds: constructor size at the click
  // point, the dragged rectangle, or centered in the parent at constructor
  // size.
  TPlacementMode = (pmDefaultSize, pmSizedRect, pmCentered);

  // Liveness flag shared with deferred closures, which can outlive the
  // designer and read the flag before touching the designer.
  TDesignerAlive = class(TInterfacedObject)
  public
    // Set False when the owning designer's destructor starts.
    Alive: Boolean;
  end;

  // Sends a rename request to the owning window; returns a refusal message,
  // empty when the request went out.
  TRenameRequest = function(AKind: TRenameKind; const AOldName, ANewName: string;
    const AMethods: TArray<TMethodRename>): string of object;
  // Answers whether a rename for AName is still pending at the window.
  TRenameStateQuery = function(const AName: string): Boolean of object;

  // Designer for one document: implements IDesignerHook on the hook host and
  // holds the selection, the editing gestures, undo recording and the save
  // flow. IDesignerNotify is implemented as well because FindRootDesigner
  // queries the root for it by GUID; component packages arrive that way.
  TFormDesigner = class(TObject, IDesignerHook, IDesignerNotify,
    IComponentRename)
  private
    FForm: TCustomForm;
    FRoot: TComponent;
    FSurfaceControl: TWinControl;
    FRootCanvas: TCanvas;
    FIconProvider: IPaletteIconProvider;
    FLog: TDesignLog;
    FFileName: string;
    FEventMap: TEventNameMap;
    FPreserved: TPreservedModel;
    FFrames: TFrameInstances;
    FAncestor: TDesignDocument;
    FLinkedModules: TArray<TLinkedModule>;
    FUndoStack: TUndoStack;
    FOnSaveRequest: TNotifyEvent;
    FOnUndoRequest: TNotifyEvent;
    FOnRedoRequest: TNotifyEvent;
    FOnContextMenu: TNotifyEvent;
    FOnSelectionChanged: TNotifyEvent;
    FOnStructureChanged: TNotifyEvent;
    FOnGeometryChanged: TNotifyEvent;
    FOnDirtyChanged: TNotifyEvent;
    FOnSaved: TNotifyEvent;
    FOnModified: TNotifyEvent;
    FOnCreationFinished: TNotifyEvent;
    FOnComponentsChanged: TNotifyEvent;
    FCodeCoupling: ICodeCoupling;
    FCouplingQuery: TCodeCouplingQuery;
    FRenameRequest: TRenameRequest;
    FRenameQuery: TRenameStateQuery;
    FLoadedState: TLoadedFormState;
    FSelected: TComponent;
    FSelection: TList<TComponent>;
    FOutlines: TObjectList<TDragFrame>;
    FHandles: THandleSet;
    FTiles: TTileLayer;
    FDirty: Boolean;
    // Set by BeginEditing; a Modified report before it is the load, not an
    // edit.
    FEditing: Boolean;
    // Read-only guard: a load left references unresolved, so an edit could
    // drop them from the file on save. Set and lifted by the shell window.
    FGuarded: Boolean;
    FIsControl: Boolean;
    // CanPaste answered from the last read, keyed by the clipboard sequence
    // number so an idle-time action update does not re-read the clipboard.
    FClipboardSequence: Cardinal;
    FClipboardPastable: Boolean;
    FGridSize: Integer;
    FSnapToGrid: Boolean;
    FTrackGeometry: Boolean;
    FLastClientSize: TPoint;
    FDragKind: TDragKind;
    FDragAnchor: TPoint;
    FDragOrigin: TRect;
    FDragRect: TRect;
    FDragParent: TWinControl;
    FDragFrame: TDragFrame;
    FResizeHandle: THandleKind;
    FArmedItem: TPaletteItem;
    FFrameWindowProc: TWndMethod;
    FSizeGestureChanged: Boolean;
    FSizeGestureRunning: Boolean;
    FExternalGesture: Boolean;
    FHostDesigner: DesignIntf.IDesigner;
    FHostDesignerObject: TVallentaDesigner;
    // Non-component selection (e.g. collection items) requested by a hosted
    // editor; cleared by the next component selection change.
    FAuxSelection: TArray<TPersistent>;
    FAliveFlag: TDesignerAlive;
    FAliveKeep: IInterface;
    FHostModifiedQueued: Boolean;
    FOwnGridEdits: Integer;
    // Snapshot taken after the last completed step; the before-state for
    // changes announced only afterwards, such as hosted editor edits.
    FSettledImage: TDocumentSnapshot;
    FSettleQueued: Boolean;
    FImageStale: Boolean;
    procedure SetExternalGesture(AValue: Boolean);
    procedure QueueSettle;
    procedure GestureEnded;
    procedure Settle;
    procedure PushSettledImage;
    function GetHostDesigner: DesignIntf.IDesigner;
    procedure HostSelectionRequested(Sender: TObject);
    procedure HostModified(Sender: TObject);
    procedure NotifySelection;
    procedure StructureChanged;
    procedure SetCodeCoupling(const AValue: ICodeCoupling);
    procedure SurfaceSelectionChanged;
    procedure SinkChrome;
    procedure DeletePlaceholder(APiece: TPreservedPiece);
    procedure DropPreservedIn(AComponent: TComponent);
    procedure ForgetFramesIn(AComponent: TComponent);
    procedure BeginSizeGesture;
    procedure EndSizeGesture;
    procedure HookFrameWindowProc;
    procedure FrameWindowProc(var Message: TMessage);
    procedure HandleDrag(Kind: THandleKind; Stage: THandleDragStage);
    function SwallowNonClient(Sender: TControl; var Message: TMessage): Boolean;
    function CreationMsg(Sender: TControl; var Message: TMessage): Boolean;
    function ControlClaimsMouse(Sender: TControl;
      const Message: TMessage): Boolean;
    function RootControl: TWinControl;
    function BelongsToDocument(AControl: TControl): Boolean;
    function DeepestDesignedAt(AFrom: TControl;
      const AScreen: TPoint): TControl;
    function ClickTarget(Sender: TControl): TComponent;
    procedure FocusSurface;
    procedure BeginMoveDrag(Sender: TControl);
    procedure BeginCreateDrag(Sender: TControl);
    procedure ContinueCreateDrag;
    procedure EndCreateDrag;
    function ComputeCreateRect(const CursorPos: TPoint): TRect;
    function AcceptingParent(AControl: TControl): TWinControl;
    function PlaceControl(AItem: TPaletteItem; AParent: TWinControl;
      const ABounds: TRect; AMode: TPlacementMode): TControl;
    function PlaceNonVisual(AItem: TPaletteItem; X, Y: Integer): TComponent;
    procedure FinishCreation(AComponent: TComponent; const AWhere: string);
    function CopyableSelection: TArray<TComponent>;
    function WriteSelectionToClipboard: Boolean;
    function ClipboardText(out AText: string): Boolean;
    function ClipboardFragment(out AText: string): Boolean;
    function PasteName(const AName: string): string;
    procedure PasteHandlerName(const AOldComponent, ANewComponent,
      AEvent: string; var AMethod: string);
    function PasteTarget: TWinControl;
    procedure OffsetPasted(const AComponents: TArray<TComponent>);
    procedure RequestPastedHandlers(const AHandlers: TArray<TFragmentHandler>);
    procedure ContinueDrag;
    procedure EndDrag;
    function HandleKeyDown(CharCode: Word): Boolean;
    procedure SelectParent;
    procedure MakePrimary(AComponent: TComponent);
    procedure BeginMarquee;
    procedure CommitMarquee;
    function ComputeMarqueeRect(const CursorPos: TPoint): TRect;
    function SelectedControls: TArray<TControl>;
    function SiblingIndex(AControl: TControl): Integer;
    function PrimaryBounds: TRect;
    procedure UpdateOutlines;
    procedure UpdateHandles;
    procedure UpdateTiles;
    procedure InvalidateSurface;
    procedure SyncFrameHost;
    procedure ApplyBounds(AControl: TControl; ALeft, ATop, AWidth, AHeight: Integer);
    function ComputeDragRect(const CursorPos: TPoint): TRect;
    procedure CommitDrag;
    procedure CancelDrag;
    procedure ShowDragFrame;
    procedure PaintFrameOn(DC: HDC);
    procedure PaintHostArea;
    function SnapEnabled: Boolean;
    procedure NoteFormSize(AWidth, AHeight: Integer);
  protected
    { IInterface: not reference counted; _AddRef and _Release return -1 and
      the creator frees this object. }
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
    { IDesignerNotify }
    procedure Modified;
    procedure Notification(AnObject: TPersistent; Operation: TOperation);
    procedure CanInsertComponent(AComponent: TComponent);
    { IDesignerHook }
    function GetCustomForm: TCustomForm;
    procedure SetCustomForm(Value: TCustomForm);
    function GetIsControl: Boolean;
    procedure SetIsControl(Value: Boolean);
    function IsDesignMsg(Sender: TControl; var Message: TMessage): Boolean;
    procedure PaintGrid;
    procedure PaintMenu;
    procedure UpdateCaption(AVisible: Boolean; AUpdateFrame: Boolean);
    procedure ValidateRename(AComponent: TComponent; const CurName, NewName: string);
    procedure UpdateDesigner;
    function UniqueName(const BaseName: string): string;
    function GetRoot: TComponent;
    function DesignPPI(AControl: TWinControl): Integer;
    function GetExcludedStyleElements(AControl: TControl): TStyleElements;
    function GetDesignerHighDPIMode: TVCLDesignerHighDPIMode;
  public
    // AHost carries the designer hook and is nil for a data module; ARoot is
    // the designed component GetRoot answers with. ALog may be nil.
    constructor Create(AHost: TCustomForm; ARoot: TComponent; ALog: TDesignLog);
    destructor Destroy; override;
    // Hands over the load results a save needs. The event map, the preserved
    // model and the frames are freed with this designer.
    procedure AttachLoaded(const AFileName: string; AEventMap: TEventNameMap;
      APreserved: TPreservedModel; AFrames: TFrameInstances;
      const AAncestor: TDesignDocument; const AState: TLoadedFormState);
    // Takes the modules the load linked for cross-module references; freed
    // with this designer, after the ancestor that holds references into them.
    procedure AdoptLinkedModules(const AModules: TArray<TLinkedModule>);
    // True for a component declared by the ancestor form. It may be changed
    // here but not removed or renamed; a descendant's file cannot express
    // that.
    function IsInherited(AComponent: TComponent): Boolean;
    // Components needing a field in this document's own unit. Placeholders,
    // inherited components and frame-held components are excluded; their
    // fields are declared elsewhere or do not exist.
    function DesignedFields: TArray<TFieldEntry>;
    // True when an editor session is attached to the unit beside this
    // document; answered through OnCouplingQuery.
    function CodeCouplingAvailable: Boolean;
    { IComponentRename }
    // Validates a component rename and sends it to the editor; returns a
    // refusal message, empty when the request went out.
    function BeginRename(AComponent: TComponent; const ANewName: string): string;
    // True while a rename for this component's name is pending at the window;
    // keyed by name because a restore replaces component instances.
    function RenameInFlight(AComponent: TComponent): Boolean;
    // Why AComponent cannot take ANewName; empty when it can. Called by
    // BeginRename, ValidateRename and ApplyRename.
    function RenameRefusal(AComponent: TComponent; const ANewName: string): string;
    // The component's handlers whose names follow the IDE pattern for
    // AOldName, paired with the names they take under ANewName.
    function PatternHandlers(AComponent: TComponent;
      const AOldName, ANewName: string): TArray<TMethodRename>;
    // Sends a single handler rename to the editor (a hosted editor renaming a
    // method); returns a refusal message, empty when the request went out.
    function BeginMethodRename(const AOldName, ANewName: string): string;
    // Applies a confirmed rename: component name, handler names and coupling
    // key, in that order, and marks the document dirty. False when the rename
    // could not be applied here, e.g. after an undo in between.
    function ApplyRename(AKind: TRenameKind; const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>;
      const ANewClassName: string): Boolean;
    // Parents each preserved block's placeholder onto its named container, or
    // onto SurfaceControl when the container is the root. Call once the
    // document is presented and SurfaceControl is set; a block whose container
    // is the root is skipped while SurfaceControl is nil.
    procedure ShowPlaceholders;
    // Replaces the preserved model with the one an undo step carried, frees
    // the previous one and rebuilds the placeholders.
    procedure AdoptPreserved(APreserved: TPreservedModel);
    // Resolves a name to a component of the root or to a preserved block's
    // placeholder; preserved names are reserved, so at most one matches.
    function ComponentNamed(const AName: string): TComponent;
    // Makes AComponent the sole selection; nil or the hook host selects the
    // root.
    procedure SelectComponent(AComponent: TComponent);
    // Adds AComponent to the selection or removes it; an added one becomes the
    // primary. The root never joins a group.
    procedure ToggleSelection(AComponent: TComponent);
    // Replaces the selection; the last entry becomes the primary and an empty
    // array selects the root.
    procedure SelectMany(const AComponents: TArray<TComponent>);
    // True when AComponent is part of the current selection.
    function IsSelected(AComponent: TComponent): Boolean;
    // Number of selected components; at least 1 (the root).
    function SelectionCount: Integer;
    // Selected component at AIndex.
    function SelectionAt(AIndex: Integer): TComponent;
    // The selection with the primary first, as the object inspector edits it.
    function SelectedInstances: TArray<TComponent>;
    // Selection in TPersistent terms: the auxiliary selection when one is
    // set, otherwise the selected components.
    function SelectedPersistents: TArray<TPersistent>;
    // Selects one instance: a component goes through SelectComponent, anything
    // else becomes the auxiliary selection.
    procedure SelectPersistent(AInstance: TPersistent);
    // Opens a property-grid write bracket; hosted-designer Modified events
    // inside it are the grid's own write, not an external edit.
    procedure BeginGridEdit;
    // Closes a BeginGridEdit bracket.
    procedure EndGridEdit;
    // Verbs of the primary selection's component editor; empty when hosted
    // editors are unavailable.
    function ComponentVerbs: TArray<string>;
    // Runs one component-editor verb (-1 for the default action). Pushes an
    // undo entry, dropped again when the editor reported no change.
    procedure RunComponentVerb(AVerb: Integer);
    // The double-click gesture: the component editor's default verb, refused
    // when there are no verbs and no editor session for a default handler.
    procedure RunDefaultComponentEditor;
    // Raises OnContextMenu; entry point for surfaces with their own input
    // handling, e.g. the icon canvas.
    procedure RequestContextMenu;
    // Aligns the selected controls to the primary selection. The
    // center-in-window actions use the parent's client area instead and move
    // a single selected control as well; the space-equally actions distribute
    // the middle controls between the outermost two.
    procedure AlignSelection(AHorizontal: TAlignHorizontal;
      AVertical: TAlignVertical);
    // Sizes the selected controls to the primary selection's width, its
    // height, or both.
    procedure SizeSelection(AWidth, AHeight: TSizeMatch);
    // Moves the selected controls to one end of their parent's child order,
    // which is their z-order and the order they are written in. Graphic and
    // windowed controls each move within their own group: the VCL keeps every
    // graphic child before every windowed one.
    procedure RestackSelection(AStep: TZOrderStep);
    // True when the selection holds a parented control a z-order step can
    // move. False for a guarded document, and for a selection holding nothing
    // but the root, placeholders or non-visual components.
    function CanRestackSelection: Boolean;
    // Applies AOrder as the tab order of one container's children. Refused
    // when the container holds a windowed placeholder.
    procedure ApplyTabOrder(const AOrder: TArray<TComponent>);
    // Applies AOrder as the creation order of the root's components.
    procedure ApplyCreationOrder(const AOrder: TArray<TComponent>);
    // Enters creation mode: the next click or drag places AItem instead of
    // selecting or moving.
    procedure ArmCreation(AItem: TPaletteItem);
    // Leaves creation mode without placing; raises OnCreationFinished.
    procedure DisarmCreation;
    // The palette double-click gesture: places AItem centered in the root at
    // constructor size.
    procedure CreateCentered(AItem: TPaletteItem);
    // Places the armed item as an icon tile at X,Y; entry point for the data
    // module's icon canvas, which routes its own clicks.
    procedure PlaceArmedAt(X, Y: Integer);
    // Moves a non-visual component's tile to X,Y, which is stored in the
    // component's DesignInfo.
    procedure MoveTile(AComponent: TComponent; X, Y: Integer);
    // Arrow-key gesture: plain moves the selection by one grid step, Ctrl
    // moves by 1 px, Shift resizes the primary by 1 px.
    procedure NudgeSelection(CharCode: Word; Shift: TShiftState);
    // Deletes the selection without confirmation; undo restores it. Inherited
    // and frame-held components are skipped; a lone placeholder is confirmed
    // in a dialog first.
    procedure DeleteSelection;
    // True when the selection holds at least one component a copy can write.
    function CanCopySelection: Boolean;
    // The selection as the fragment text a copy writes, one block per
    // outermost member; empty when nothing in it can be copied.
    function SelectionAsFragment: string;
    // Writes the selection to the clipboard as a component fragment. Allowed
    // on a guarded document.
    procedure CopySelection;
    // Copies the selection and then deletes it; the delete's own entry is the
    // one undo step a cut leaves.
    procedure CutSelection;
    // True when the clipboard holds text beginning with a component block and
    // the document can take one.
    function CanPaste: Boolean;
    // Reads a component fragment into the document: names that collide are
    // given new ones, references between the pasted components follow, and a
    // pattern-named handler follows its component's new name. A hand-named
    // handler and one named for another component keep pointing at the method
    // the unit already declares. One undo entry; a refusal creates nothing.
    procedure PasteFragment(const AText: string);
    // Pastes the fragment the clipboard holds.
    procedure PasteFromClipboard;
    // Routes to OnSaveRequest, or saves directly when it is unassigned.
    procedure RequestSave;
    // Raises OnUndoRequest; refused while a gesture is in flight.
    procedure RequestUndo;
    // Raises OnRedoRequest; refused while a gesture is in flight.
    procedure RequestRedo;
    // Records the pre-change state; call before applying the step. Public
    // because the inspector and the icon canvas edit the same document.
    procedure PushUndo(AOperation: TUndoOperation);
    // Removes the newest undo entry; used when the step it was pushed for did
    // not happen after all.
    procedure DropUndo;
    // Streams the document into an undo snapshot, together with a clone of
    // the preserved model and the name of the current selection.
    function CaptureSnapshot: TDocumentSnapshot;
    // Sets the dirty flag directly; used when a restore re-establishes the
    // flag from the history.
    procedure MarkDirty(AValue: Boolean);
    // Snaps a coordinate to the grid; holding Alt suspends snapping.
    function Snap(Value: Integer): Integer;
    // Called once the document is on screen. From here on a Modified report
    // counts as an edit, and the first settled image is queued.
    procedure BeginEditing;
    // Guards the document read-only: gestures, the palette, the inspector
    // and Save are refused until the guard is lifted. Viewing and selection
    // are still allowed.
    procedure GuardReadOnly;
    // Lifts the read-only guard; edits and Save are accepted again.
    procedure LiftGuard;
    // Called after an outside pane changed the selection's properties; updates
    // the handles and marks the document dirty.
    procedure NotifyEdited;
    // Called after a hosted editor dialog reported changes. The dialog may
    // have added or removed components without any notification, so the
    // structure is re-scanned rather than only repainted.
    procedure NotifyEditorChanged;
    // True while a drag runs here, while ExternalGesture is set, and while
    // the root's modal sizing loop runs. Undo, redo, snapshot capture and the
    // recovery journal wait for it to clear.
    function GestureInFlight: Boolean;
    // Writes the document to its file, clears the dirty flag and raises
    // OnSaved. Refused for a guarded document; a failed write is logged and
    // shown in a dialog. False in both cases.
    function Save: Boolean;
    // Writes the document to APath through the regular save pipeline without
    // touching the dirty flag, the log or any dialog; failures raise.
    procedure WriteTo(const APath: string);
    // Prompts to save a dirty document; False when the prompt is cancelled or
    // the save fails.
    function ConfirmClose: Boolean;
    // Logs the document's DPI facts, with a warning when the form's stored PPI
    // differs from the design PPI.
    procedure LogDpi;
    // One-line DPI description for the log.
    function DescribeDpi: string;
    // True while the document has unsaved changes.
    property Dirty: Boolean read FDirty;
    // True while the document is guarded read-only.
    property Guarded: Boolean read FGuarded;
    // The form carrying the designer hook: the designed form itself, the host
    // of a frame, or nil for a data module.
    property Form: TCustomForm read FForm;
    // The designed root component.
    property Root: TComponent read FRoot;
    // IDesigner for hosted property and component editors. Built on first use
    // and refreshed with the current selection on every read.
    property HostDesigner: DesignIntf.IDesigner read GetHostDesigner;
    // Classification of the designed root.
    property RootKind: TDesignRootClass read FLoadedState.RootKind;
    // Optional log target; nil disables logging.
    property Log: TDesignLog read FLog;
    // Grid spacing in px.
    property GridSize: Integer read FGridSize;
    // The primary selection; the root when nothing else is selected.
    property Selected: TComponent read FSelected;
    // Palette item armed for placement; nil outside creation mode.
    property ArmedItem: TPaletteItem read FArmedItem;
    // Path of the loaded form file.
    property FileName: string read FFileName;
    // Handler-name map for the document's events; freed with the designer.
    property EventMap: TEventNameMap read FEventMap;
    // Blocks the load could not read, kept verbatim; freed with the designer.
    property Preserved: TPreservedModel read FPreserved;
    // The document's frame instances plus the pristine instance per frame
    // class that a save diffs the live ones against.
    property Frames: TFrameInstances read FFrames;
    // The ancestor-only document a save diffs against; its Root is nil unless
    // the document descends from another form.
    property Ancestor: TDesignDocument read FAncestor;
    // Undo history; not freed here, because a restore replaces the document
    // while the history stays. The designer records and drops entries; the
    // restore is driven from outside.
    property UndoStack: TUndoStack read FUndoStack write FUndoStack;
    // Set by a surface running its own gesture (the icon canvas) so undo is
    // refused while it runs, whichever way the request came in.
    property ExternalGesture: Boolean read FExternalGesture
      write SetExternalGesture;
    // Load-time state the live root cannot reproduce; handed to the rebuilt
    // document on restore.
    property LoadedState: TLoadedFormState read FLoadedState;
    // Icon source for non-visual component tiles.
    property IconProvider: IPaletteIconProvider read FIconProvider;
    // The control showing the document, repainted when a tile moves. A data
    // module sets its icon canvas here.
    property SurfaceControl: TWinControl read FSurfaceControl
      write FSurfaceControl;
    // Class name from the form file header, which the design stub class
    // cannot report.
    property RootClassName: string read FLoadedState.RootClassName;
    // Raised instead of saving directly, so the shell routes every save
    // through one action regardless of which control had focus.
    property OnSaveRequest: TNotifyEvent read FOnSaveRequest write FOnSaveRequest;
    // Raised instead of restoring directly: a restore replaces this designer
    // and must not run inside its own message handling. The shell defers it.
    property OnUndoRequest: TNotifyEvent read FOnUndoRequest write FOnUndoRequest;
    // Redo counterpart of OnUndoRequest.
    property OnRedoRequest: TNotifyEvent read FOnRedoRequest write FOnRedoRequest;
    // Raised on right-button release, after the press has selected; the menu
    // host reads the selection and the cursor position itself.
    property OnContextMenu: TNotifyEvent read FOnContextMenu
      write FOnContextMenu;
    // Raised after every selection change.
    property OnSelectionChanged: TNotifyEvent read FOnSelectionChanged
      write FOnSelectionChanged;
    // Raised when components were added, removed, renamed or reordered.
    property OnStructureChanged: TNotifyEvent read FOnStructureChanged
      write FOnStructureChanged;
    // Raised after bounds or tile positions changed.
    property OnGeometryChanged: TNotifyEvent read FOnGeometryChanged
      write FOnGeometryChanged;
    // Raised when the Dirty flag flips.
    property OnDirtyChanged: TNotifyEvent read FOnDirtyChanged write FOnDirtyChanged;
    // Raised after a successful write to the file. Separate from
    // OnDirtyChanged: an undo back to the saved depth also clears Dirty but
    // writes nothing.
    property OnSaved: TNotifyEvent read FOnSaved write FOnSaved;
    // Raised for every change, not only the first after a save; the recovery
    // journal needs more than the one-bit dirty flag.
    property OnModified: TNotifyEvent read FOnModified write FOnModified;
    // Raised for every way a placement ends - completed, cancelled or
    // disarmed - so the palette releases its pressed button in one place.
    property OnCreationFinished: TNotifyEvent read FOnCreationFinished
      write FOnCreationFinished;
    // Raised together with OnStructureChanged, for the owning window; a pane
    // takes the other event.
    property OnComponentsChanged: TNotifyEvent read FOnComponentsChanged
      write FOnComponentsChanged;
    // Access to the coupled unit; nil while the document is not coupled.
    // Hosted editors are handed it and keep it for the length of a dialog.
    property CodeCoupling: ICodeCoupling read FCodeCoupling write SetCodeCoupling;
    // Answers CodeCouplingAvailable; assigned by the owning window, which the
    // shell informs when an editor session attaches or detaches.
    property OnCouplingQuery: TCodeCouplingQuery read FCouplingQuery
      write FCouplingQuery;
    // Sends a validated rename to the window, which holds the callback
    // because the answer can arrive after a restore has replaced this
    // designer.
    property OnRenameRequest: TRenameRequest read FRenameRequest
      write FRenameRequest;
    // Answers whether a rename for a name is still pending at the window.
    property OnRenameQuery: TRenameStateQuery read FRenameQuery
      write FRenameQuery;
  end;

const
  // Grid, gesture and clipboard defaults.
  DefaultGridSize = 8; // px
  DragThreshold = 3; // px of cursor travel before a pending drag becomes real
  MinimumCreateSize = 8; // px
  MaxPasteOffsets = 32; // grid steps
  ClipboardAttempts = 10;
  ClipboardRetryDelay = 20; // ms

implementation

uses
  System.SysUtils,
  System.UITypes,
  System.TypInfo,
  System.Generics.Defaults,
  Vcl.Clipbrd,
  Vcl.Dialogs,
  Vallenta.FormEditor.Streaming.Saver,
  Vallenta.FormEditor.Streaming.TextSpans,
  Vallenta.FormEditor.Packages.Host,
  Vallenta.FormEditor.Packages.Icons;

{ TFormDesigner }

constructor TFormDesigner.Create(AHost: TCustomForm; ARoot: TComponent;
  ALog: TDesignLog);
begin
  inherited Create;
  FAliveFlag := TDesignerAlive.Create;
  FAliveFlag.Alive := True;
  FAliveKeep := FAliveFlag;
  FForm := AHost;
  FRoot := ARoot;
  FSelected := ARoot;
  FSelection := TList<TComponent>.Create;
  FSelection.Add(ARoot);
  FOutlines := TObjectList<TDragFrame>.Create(True);
  FLog := ALog;
  FGridSize := DefaultGridSize;
  FSnapToGrid := True;
  FIconProvider := IconProviderOver(TGenericGlyphProvider.Create);
  FHandles := THandleSet.Create(HandleDrag);
  FDragFrame := TDragFrame.Create;
  // Chrome is parented into the host window, never into a designed container:
  // a container that manages its children (a TToolBar) would give it a slot.
  FHandles.Chrome := FForm;
  FDragFrame.Chrome := FForm;
  if FForm <> nil then
    FTiles := TTileLayer.CreateLayer(FRoot, FIconProvider);
  if FRoot is TWinControl then
    FSurfaceControl := TWinControl(FRoot);
  HookFrameWindowProc;
  if FForm <> nil then
    FForm.Designer := Self;
end;

procedure TFormDesigner.NotifyEditorChanged;
begin
  NotifyEdited;
  StructureChanged;
end;

procedure TFormDesigner.StructureChanged;
begin
  if Assigned(FOnStructureChanged) then
    FOnStructureChanged(Self);
  if Assigned(FOnComponentsChanged) then
    FOnComponentsChanged(Self);
end;

procedure TFormDesigner.SetCodeCoupling(const AValue: ICodeCoupling);
begin
  FCodeCoupling := AValue;
  if FHostDesignerObject <> nil then
    FHostDesignerObject.Coupling := AValue;
end;

function TFormDesigner.CodeCouplingAvailable: Boolean;
begin
  Result := Assigned(FCouplingQuery) and FCouplingQuery;
end;

function TFormDesigner.DesignedFields: TArray<TFieldEntry>;
var
  I: Integer;
  Component: TComponent;
begin
  Result := nil;
  for I := 0 to FRoot.ComponentCount - 1 do
  begin
    Component := FRoot.Components[I];
    if (Component.Name = '') or IsPlaceholder(Component) or
       IsInherited(Component) or (FrameInstanceHolding(Component) <> nil) then
      Continue;
    Result := Result + [FieldOf(Component)];
  end;
end;

procedure TFormDesigner.HostSelectionRequested(Sender: TObject);
var
  Requested: TArray<TPersistent>;
  Components: TArray<TComponent>;
  Instance: TPersistent;
  AllComponents: Boolean;
begin
  Requested := FHostDesignerObject.RequestedSelection;
  // An empty request is the editor deselecting its sub-objects before freeing
  // them; ignoring it would leave freed items in FAuxSelection.
  if Length(Requested) = 0 then
  begin
    if Length(FAuxSelection) > 0 then
    begin
      FAuxSelection := nil;
      NotifySelection;
    end;
    Exit;
  end;
  AllComponents := True;
  for Instance in Requested do
    if not (Instance is TComponent) then
    begin
      AllComponents := False;
      Break;
    end;
  if AllComponents then
  begin
    Components := nil;
    for Instance in Requested do
      Components := Components + [TComponent(Instance)];
    if Length(Components) = 1 then
      SelectComponent(Components[0])
    else
      SelectMany(Components);
  end
  else
  begin
    FAuxSelection := Requested;
    NotifySelection;
  end;
end;

function TFormDesigner.SelectedPersistents: TArray<TPersistent>;
var
  Selected: TArray<TComponent>;
  I: Integer;
begin
  if Length(FAuxSelection) > 0 then
    Exit(FAuxSelection);
  Selected := SelectedInstances;
  SetLength(Result, Length(Selected));
  for I := 0 to High(Selected) do
    Result[I] := Selected[I];
end;

procedure TFormDesigner.NotifySelection;
var
  List: IDesignerSelections;
  Instance: TPersistent;
begin
  if FHostDesignerObject <> nil then
  begin
    FHostDesignerObject.SetSelection(SelectedPersistents);
    List := CreateSelectionList;
    for Instance in SelectedPersistents do
      List.Add(Instance);
    NotifySelectionChanged(FHostDesigner, List);
  end;
  if Assigned(FOnSelectionChanged) then
    FOnSelectionChanged(Self);
end;

procedure TFormDesigner.SurfaceSelectionChanged;
begin
  FAuxSelection := nil;
  NotifySelection;
end;

procedure TFormDesigner.BeginGridEdit;
begin
  Inc(FOwnGridEdits);
end;

procedure TFormDesigner.EndGridEdit;
begin
  if FOwnGridEdits > 0 then
    Dec(FOwnGridEdits);
end;

function TFormDesigner.ComponentVerbs: TArray<string>;
begin
  if not HostedEditors then
    Exit(nil);
  Result := ComponentEditorVerbs(ComponentEditorFor(FSelected, GetHostDesigner));
end;

procedure TFormDesigner.RunComponentVerb(AVerb: Integer);
var
  Editor: IComponentEditor;
  Before: Integer;
  Error: string;
begin
  if not HostedEditors then
    Exit;
  Editor := ComponentEditorFor(FSelected, GetHostDesigner);
  if Editor = nil then
    Exit;
  PushUndo(uoProperty);
  BeginGridEdit;
  Before := FHostDesignerObject.ModificationCount;
  try
    if not RunComponentEditor(Editor, AVerb, Error) and (FLog <> nil) then
      FLog.AddFmt(lsWarn, 'the component editor of %s failed: %s',
        [FSelected.Name, Error]);
  finally
    EndGridEdit;
    Editor := nil;
  end;
  if FHostDesignerObject.ModificationCount > Before then
    NotifyEditorChanged
  else
    DropUndo;
end;

procedure TFormDesigner.RunDefaultComponentEditor;
begin
  if (Length(ComponentVerbs) = 0) and not CodeCouplingAvailable then
  begin
    if FLog <> nil then
      FLog.Add(lsWarn, 'a double-click creates the default event handler, ' +
        'which needs VS Code attached - this document is not coupled');
    Exit;
  end;
  RunComponentVerb(-1);
end;

procedure TFormDesigner.RequestContextMenu;
begin
  if Assigned(FOnContextMenu) then
    FOnContextMenu(Self);
end;

procedure TFormDesigner.SelectPersistent(AInstance: TPersistent);
begin
  if AInstance is TComponent then
    SelectComponent(TComponent(AInstance))
  else if AInstance <> nil then
  begin
    FAuxSelection := [AInstance];
    NotifySelection;
  end;
end;

// Deferred: Modified also fires inside a synchronous grid write, where
// rebuilding the grid would free the row whose method is still on the stack.
procedure TFormDesigner.HostModified(Sender: TObject);
var
  Flag: TDesignerAlive;
  Keep: IInterface;
begin
  if (FOwnGridEdits > 0) or FHostModifiedQueued then
    Exit;
  FHostModifiedQueued := True;
  Flag := FAliveFlag;
  Keep := FAliveKeep;
  TThread.ForceQueue(nil,
    procedure
    begin
      if (Keep = nil) or not Flag.Alive then
        Exit;
      FHostModifiedQueued := False;
      PushSettledImage;
      NotifyEditorChanged;
    end);
end;

function TFormDesigner.GetHostDesigner: DesignIntf.IDesigner;
begin
  if FHostDesigner = nil then
  begin
    FHostDesignerObject := TVallentaDesigner.Create(FRoot, FLog, FEventMap,
      function(ABase: string): string
      begin
        Result := UniqueName(ABase);
      end);
    FHostDesignerObject.OnSelectionRequest := HostSelectionRequested;
    FHostDesignerObject.OnModified := HostModified;
    FHostDesignerObject.OnRenameMethod := BeginMethodRename;
    FHostDesignerObject.Coupling := FCodeCoupling;
    FHostDesigner := FHostDesignerObject;
  end;
  FHostDesignerObject.SetSelection(SelectedPersistents);
  Result := FHostDesigner;
end;

destructor TFormDesigner.Destroy;
var
  I: Integer;
begin
  FAliveFlag.Alive := False;
  // Design windows are closed before the designer they reference is released.
  if FHostDesigner <> nil then
    NotifyDesignerClosed(FHostDesigner);
  // Released before the event map it reads and before any package can be
  // unloaded from under it.
  FHostDesigner := nil;
  FHostDesignerObject := nil;
  if Assigned(FFrameWindowProc) then
    TWinControl(FRoot).WindowProc := FFrameWindowProc;
  if FForm <> nil then
    FForm.Designer := nil;
  FRootCanvas.Free;
  FTiles.Free;
  FDragFrame.Free;
  FOutlines.Free;
  FSelection.Free;
  FHandles.Free;
  FSettledImage.Free;
  // Freed before the document: placeholders are parented into it and would be
  // freed twice if their container went first.
  FPreserved.Free;
  FFrames.Free;
  FreeDesignDocument(FAncestor);
  // After the ancestor: its components hold references into the linked
  // modules too, and free notifications clean up in this order.
  for I := 0 to High(FLinkedModules) do
  begin
    FreeDesignDocument(FLinkedModules[I].Document);
    FLinkedModules[I].EventMap.Free;
  end;
  FEventMap.Free;
  inherited Destroy;
end;

procedure TFormDesigner.AttachLoaded(const AFileName: string;
  AEventMap: TEventNameMap; APreserved: TPreservedModel;
  AFrames: TFrameInstances; const AAncestor: TDesignDocument;
  const AState: TLoadedFormState);
begin
  FFileName := AFileName;
  FEventMap := AEventMap;
  FPreserved := APreserved;
  FFrames := AFrames;
  FAncestor := AAncestor;
  FLoadedState := AState;
end;

procedure TFormDesigner.AdoptLinkedModules(const AModules: TArray<TLinkedModule>);
begin
  FLinkedModules := AModules;
end;

function TFormDesigner.IsInherited(AComponent: TComponent): Boolean;
begin
  Result := (FAncestor.Root <> nil) and (AComponent <> nil) and
    (AComponent.Name <> '') and
    (FAncestor.Root.FindComponent(AComponent.Name) <> nil);
end;

procedure TFormDesigner.ShowPlaceholders;
begin
  if FPreserved <> nil then
    FPreserved.BuildPlaceholders(FRoot, FSurfaceControl);
end;

procedure TFormDesigner.AdoptPreserved(APreserved: TPreservedModel);
begin
  if APreserved = FPreserved then
    Exit;
  FPreserved.Free;
  FPreserved := APreserved;
  ShowPlaceholders;
end;

function TFormDesigner.ComponentNamed(const AName: string): TComponent;
begin
  Result := FRoot.FindComponent(AName);
  if (Result = nil) and (FPreserved <> nil) then
    Result := FPreserved.PlaceholderNamed(AName);
end;

function TFormDesigner.DescribeDpi: string;
begin
  if FForm = nil then
    Result := Format('DPI: designer=%d screen=%d (a data module has no window)',
      [DesignPPI(nil), Screen.PixelsPerInch])
  else
    Result := Format('DPI: designer=%d screen=%d host.CurrentPPI=%d ' +
      'host.PixelsPerInch=%d ClientWidth=%d ClientHeight=%d',
      [DesignPPI(FForm), Screen.PixelsPerInch, FForm.CurrentPPI,
       FForm.PixelsPerInch, FForm.ClientWidth, FForm.ClientHeight]);
end;

procedure TFormDesigner.MarkDirty(AValue: Boolean);
begin
  if FDirty = AValue then
    Exit;
  FDirty := AValue;
  if Assigned(FOnDirtyChanged) then
    FOnDirtyChanged(Self);
end;

{ undo }

procedure TFormDesigner.PushUndo(AOperation: TUndoOperation);
begin
  if FUndoStack <> nil then
    FUndoStack.Push(AOperation, FSelected.Name);
end;

procedure TFormDesigner.DropUndo;
begin
  if FUndoStack <> nil then
    FUndoStack.DropLast;
end;

{ the settled image }

// Deferred to the next pass of the message pump: a synchronous capture would
// miss the preserved text and selection a restore hands back afterwards.
procedure TFormDesigner.QueueSettle;
var
  Flag: TDesignerAlive;
  Keep: IInterface;
begin
  // Not queued during a gesture: GestureEnded re-queues, and queueing here
  // would post one closure per drag report for the length of the gesture.
  if (FUndoStack = nil) or FSettleQueued or GestureInFlight then
    Exit;
  FSettleQueued := True;
  Flag := FAliveFlag;
  Keep := FAliveKeep;
  TThread.ForceQueue(nil,
    procedure
    begin
      if (Keep = nil) or not Flag.Alive then
        Exit;
      FSettleQueued := False;
      // A gesture started meanwhile re-queues through GestureEnded;
      // re-queueing here would poll the message pump.
      if not GestureInFlight then
        Settle;
    end);
end;

procedure TFormDesigner.GestureEnded;
begin
  if FImageStale then
    QueueSettle;
end;

procedure TFormDesigner.Settle;
var
  Image: TDocumentSnapshot;
begin
  Image := nil;
  try
    Image := CaptureSnapshot;
  except
    on E: Exception do
      if FLog <> nil then
        FLog.AddFmt(lsError, 'a change made outside this window cannot be ' +
          'undone - recording the document state failed: %s: %s',
          [E.ClassName, E.Message]);
  end;
  // A failed capture leaves nil rather than a stale image; pushing a stale
  // image would revert one step too many.
  FSettledImage.Free;
  FSettledImage := Image;
  FImageStale := Image = nil;
end;

procedure TFormDesigner.PushSettledImage;
var
  Image: TDocumentSnapshot;
begin
  // A stale image, and any image while a gesture runs, is a step behind;
  // pushing it would revert that step as well, so nothing is pushed.
  if (FUndoStack = nil) or (FSettledImage = nil) or FImageStale or
     GestureInFlight then
    Exit;
  Image := FSettledImage;
  FSettledImage := nil;
  FUndoStack.PushImage(Image, uoEditor, FSelected.Name);
end;

// Grab handles, drag frame and outlines are entries in their parent's tab
// list; streaming before they are sunk writes TabOrder values that count them.
procedure TFormDesigner.SinkChrome;
var
  Outline: TDragFrame;
begin
  FHandles.SinkInTabOrder;
  FDragFrame.SinkInTabOrder;
  if FTiles <> nil then
    SinkBehindSiblings(FTiles);
  for Outline in FOutlines do
    Outline.SinkInTabOrder;
end;

function TFormDesigner.CaptureSnapshot: TDocumentSnapshot;
var
  SelectionName: string;
  Preserved: TPreservedModel;
begin
  // A placeholder has no Name; the preserved component's name is recorded
  // instead, which ComponentNamed resolves back to it.
  if IsPlaceholder(FSelected) then
    SelectionName := PlaceholderPiece(FSelected).ComponentName
  else if FSelected <> FRoot then
    SelectionName := FSelected.Name;
  Preserved := nil;
  if FPreserved <> nil then
    Preserved := FPreserved.Clone;
  try
    SinkChrome;
    Result := TDocumentSnapshot.Create(
      StreamDesignedForm(FRoot, FEventMap, FFrames, FAncestor.Root),
      SelectionName, Preserved);
  except
    // Freed here only while the snapshot has not taken the clone over.
    Preserved.Free;
    raise;
  end;
end;

procedure TFormDesigner.LogDpi;
begin
  if FLog = nil then
    Exit;
  FLog.Add(lsInfo, DescribeDpi);
  if (FRoot is TCustomForm) and
     (TCustomForm(FRoot).PixelsPerInch <> DesignPPI(FForm)) then
    FLog.AddFmt(lsWarn, 'the form declares PixelsPerInch = %d, but the designer ' +
      'pins the design PPI to %d - its geometry is rescaled and is not saved back',
      [TCustomForm(FRoot).PixelsPerInch, DesignPPI(FForm)]);
end;

{ IInterface }

function TFormDesigner.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := S_OK
  else
  begin
    // Component packages cast the FindRootDesigner result to
    // DesignIntf.IDesigner; every interface not implemented here is answered
    // by the hosted designer.
    GetHostDesigner;
    Result := FHostDesigner.QueryInterface(IID, Obj);
  end;
end;

function TFormDesigner._AddRef: Integer;
begin
  Result := -1;
end;

function TFormDesigner._Release: Integer;
begin
  Result := -1;
end;

{ IDesignerNotify }

procedure TFormDesigner.Modified;
begin
  // Components report here while the document is still loading (a
  // cxPageControl settles its tab index inside Loaded), which is no edit.
  if not FEditing or FGuarded then
    Exit;
  MarkDirty(True);
  FImageStale := True;
  QueueSettle;
  if Assigned(FOnModified) then
    FOnModified(Self);
end;

// Runs inside the destructor of the freed collection item: only references
// are dropped, because a rebuild here would read a half-dismantled document.
procedure TFormDesigner.Notification(AnObject: TPersistent; Operation: TOperation);
var
  Instance: TPersistent;
  Named: Boolean;
begin
  if (Operation <> opRemove) or (Length(FAuxSelection) = 0) then
    Exit;
  Named := False;
  for Instance in FAuxSelection do
    if Instance = AnObject then
    begin
      Named := True;
      Break;
    end;
  if not Named then
    Exit;
  FAuxSelection := nil;
  if FHostDesignerObject <> nil then
    FHostDesignerObject.SetSelection(SelectedPersistents);
end;

procedure TFormDesigner.CanInsertComponent(AComponent: TComponent);
begin
end;

{ IDesignerHook }

function TFormDesigner.GetCustomForm: TCustomForm;
begin
  Result := FForm;
end;

procedure TFormDesigner.SetCustomForm(Value: TCustomForm);
begin
  FForm := Value;
end;

function TFormDesigner.GetIsControl: Boolean;
begin
  Result := FIsControl;
end;

procedure TFormDesigner.SetIsControl(Value: Boolean);
begin
  FIsControl := Value;
end;

function TFormDesigner.GetRoot: TComponent;
begin
  Result := FRoot;
end;

function TFormDesigner.DesignPPI(AControl: TWinControl): Integer;
begin
  Result := 96;
end;

function TFormDesigner.GetDesignerHighDPIMode: TVCLDesignerHighDPIMode;
begin
  Result := hdmLowDPI;
end;

function TFormDesigner.GetExcludedStyleElements(AControl: TControl): TStyleElements;
begin
  Result := [];
end;

procedure TFormDesigner.PaintMenu;
begin
end;

procedure TFormDesigner.UpdateCaption(AVisible: Boolean; AUpdateFrame: Boolean);
begin
end;

procedure TFormDesigner.UpdateDesigner;
begin
end;

function TFormDesigner.RenameRefusal(AComponent: TComponent;
  const ANewName: string): string;
var
  Wanted: string;
  Holder: TComponent;
begin
  Result := '';
  if AComponent = nil then
    Exit('there is nothing here to rename');
  Wanted := Trim(ANewName);
  if Wanted = '' then
    Exit('a component has to have a name');
  if not IsValidIdent(Wanted) then
    Exit(Format('"%s" is not a name a unit could declare', [Wanted]));
  // Compared by instance, not by name: a case-only respelling is a valid
  // rename, since the form file stores the spelling.
  Holder := ComponentNamed(Wanted);
  if (Holder <> nil) and (Holder <> AComponent) then
    Exit(Format('%s is already the name of something in this form', [Wanted]));
  if (FPreserved <> nil) and FPreserved.IsReservedName(Wanted) then
    Exit(Format('%s is the name of a block this form keeps exactly as it found ' +
      'it', [Wanted]));
  if AComponent = FRoot then
    Exit('');
  if IsInherited(AComponent) then
    Exit(Format('%s belongs to the form this one is built on - its field is ' +
      'declared in that form''s unit', [AComponent.Name]));
  if FrameInstanceHolding(AComponent) <> nil then
    Exit(Format('%s belongs to a frame - its field is declared in the frame''s ' +
      'own unit', [AComponent.Name]));
end;

// Refusal raises EComponentError, which would abort the VCL's
// InsertComponent, RemoveComponent and streaming; those calls pass unchecked.
procedure TFormDesigner.ValidateRename(AComponent: TComponent;
  const CurName, NewName: string);
var
  Refusal: string;
begin
  if (AComponent = nil) or (CurName = '') or (NewName = '') or
     (csLoading in AComponent.ComponentState) then
    Exit;
  Refusal := RenameRefusal(AComponent, NewName);
  if Refusal <> '' then
    raise EComponentError.Create(Refusal);
end;

function TFormDesigner.PatternHandlers(AComponent: TComponent;
  const AOldName, ANewName: string): TArray<TMethodRename>;
begin
  Result := nil;
  if FEventMap <> nil then
    Result := PatternHandlerRenames(AComponent, FEventMap.NameFor,
      AOldName, ANewName);
end;

function TFormDesigner.BeginRename(AComponent: TComponent;
  const ANewName: string): string;
var
  Kind: TRenameKind;
  Wanted: string;
begin
  if not CodeCouplingAvailable then
    Exit('no editor is attached to this document, so a name cannot be changed ' +
      'in the unit beside it');
  if RenameInFlight(AComponent) then
    Exit('that name is already being changed');
  Result := RenameRefusal(AComponent, ANewName);
  if Result <> '' then
    Exit;
  if not Assigned(FRenameRequest) then
    Exit('this document has nowhere to send a rename');
  if AComponent = FRoot then
    Kind := rkRoot
  else
    Kind := rkComponent;
  Wanted := Trim(ANewName);
  Result := FRenameRequest(Kind, AComponent.Name, Wanted,
    PatternHandlers(AComponent, AComponent.Name, Wanted));
end;

function TFormDesigner.BeginMethodRename(const AOldName,
  ANewName: string): string;
var
  Pair: TMethodRename;
begin
  if not CodeCouplingAvailable then
    Exit('no editor is attached to this document, so a method cannot be renamed');
  if (FEventMap = nil) or not FEventMap.Holds(AOldName) then
    Exit(Format('%s is not a handler this form is wired to', [AOldName]));
  if not IsValidIdent(Trim(ANewName)) then
    Exit(Format('"%s" is not a name a unit could declare', [ANewName]));
  if not Assigned(FRenameRequest) then
    Exit('this document has nowhere to send a rename');
  Pair.OldName := AOldName;
  Pair.NewName := Trim(ANewName);
  Result := FRenameRequest(rkHandler, Pair.OldName, Pair.NewName, [Pair]);
end;

function TFormDesigner.RenameInFlight(AComponent: TComponent): Boolean;
begin
  Result := (AComponent <> nil) and Assigned(FRenameQuery) and
    FRenameQuery(AComponent.Name);
end;

function TFormDesigner.ApplyRename(AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>;
  const ANewClassName: string): Boolean;
var
  Target: TComponent;
  Pair: TMethodRename;
  Refusal: string;
begin
  Result := False;
  Target := nil;
  if AKind <> rkHandler then
  begin
    if AKind = rkRoot then
      Target := FRoot
    else
      Target := ComponentNamed(AOldName);
    if (Target = nil) or not SameText(Target.Name, AOldName) then
    begin
      if FLog <> nil then
        FLog.AddFmt(lsWarn, '%s was renamed in the unit, but this document ' +
          'no longer contains it - the form file and the unit must be ' +
          'reconciled manually', [AOldName]);
      Exit;
    end;
    // Re-validated: the document stayed editable while the request was out,
    // and something else may have taken the name meanwhile.
    Refusal := RenameRefusal(Target, ANewName);
    if Refusal <> '' then
    begin
      if FLog <> nil then
        FLog.AddFmt(lsWarn, '%s was renamed in the unit, but not here: %s',
          [AOldName, Refusal]);
      Exit;
    end;
    Target.Name := ANewName;
    // The header class name follows only when the editor reports that the
    // class in the unit moved; patching one half leaves a form that no
    // longer loads.
    if (AKind = rkRoot) and (ANewClassName <> '') then
    begin
      if FLog <> nil then
        FLog.AddFmt(lsInfo, 'the root class name %s follows the unit rename ' +
          'and is now %s', [FLoadedState.RootClassName, ANewClassName]);
      FLoadedState.RootClassName := ANewClassName;
    end;
  end;
  // Renamed once per handler, not per wired component: the method marker is
  // shared, and interning per component would split one handler into two.
  if FEventMap <> nil then
    for Pair in AMethods do
      Result := FEventMap.Rename(Pair.OldName, Pair.NewName) or Result;
  Result := Result or (Target <> nil);
  if not Result then
    Exit;
  // The ledger key must move before StructureChanged runs, or the rename
  // reads as a field removed plus a field added.
  if (Target <> nil) and (FCodeCoupling <> nil) then
    FCodeCoupling.NoteRenamed(AOldName, ANewName);
  StructureChanged;
  Modified;
end;

// Preserved block names are reserved as well: they return in the saved file
// and would collide on the next load.
function TFormDesigner.UniqueName(const BaseName: string): string;
var
  Index: Integer;
begin
  Index := 1;
  repeat
    Result := BaseName + IntToStr(Index);
    Inc(Index);
  until (FRoot.FindComponent(Result) = nil) and
    ((FPreserved = nil) or not FPreserved.IsReservedName(Result));
end;

function TFormDesigner.RootControl: TWinControl;
begin
  if FRoot is TWinControl then
    Result := TWinControl(FRoot)
  else
    Result := nil;
end;

procedure TFormDesigner.HookFrameWindowProc;
begin
  if not (FRoot is TCustomFrame) then
    Exit;
  FFrameWindowProc := TWinControl(FRoot).WindowProc;
  TWinControl(FRoot).WindowProc := FrameWindowProc;
end;

procedure TFormDesigner.FrameWindowProc(var Message: TMessage);
var
  Paint: TPaintStruct;
  DC: HDC;
begin
  // Background and grid are drawn on the paint DC itself: a separate DC
  // ignores the update region and overpaints graphic controls that Windows is
  // not redrawing.
  if (Message.Msg <> WM_PAINT) or (TWMPaint(Message).DC <> 0) then
  begin
    FFrameWindowProc(Message);
    Exit;
  end;
  DC := BeginPaint(TWinControl(FRoot).Handle, Paint);
  try
    PaintFrameOn(DC);
    TWMPaint(Message).DC := DC;
    FFrameWindowProc(Message);
    TWMPaint(Message).DC := 0;
  finally
    EndPaint(TWinControl(FRoot).Handle, Paint);
  end;
end;

{ painting }

procedure TFormDesigner.PaintFrameOn(DC: HDC);
var
  Frame: TWinControl;
begin
  Frame := RootControl;
  if Frame = nil then
    Exit;
  if FRootCanvas = nil then
    FRootCanvas := TCanvas.Create;
  FRootCanvas.Handle := DC;
  try
    PaintDesignBackground(FRootCanvas, Frame.ClientRect, TFrame(Frame).Color,
      FGridSize);
  finally
    FRootCanvas.Handle := 0;
  end;
end;

procedure TFormDesigner.PaintHostArea;
begin
  FForm.Canvas.Brush.Color := FForm.Color;
  FForm.Canvas.Brush.Style := bsSolid;
  FForm.Canvas.FillRect(FForm.ClientRect);
end;

procedure TFormDesigner.PaintGrid;
begin
  if FRoot is TCustomForm then
  begin
    PaintDesignBackground(TCustomForm(FRoot).Canvas,
      TCustomForm(FRoot).ClientRect, TCustomForm(FRoot).Color, FGridSize);
    Exit;
  end;
  // A themed frame's background paints through the host form's canvas; the
  // WindowFromDC test keeps the host fill from erasing the grid the frame
  // just drew.
  if (FForm <> nil) and FForm.Canvas.HandleAllocated and
     (WindowFromDC(FForm.Canvas.Handle) = FForm.Handle) then
    PaintHostArea;
end;

procedure TFormDesigner.InvalidateSurface;
begin
  UpdateTiles;
  if FSurfaceControl <> nil then
    FSurfaceControl.Invalidate;
end;

procedure TFormDesigner.UpdateTiles;
begin
  if FTiles <> nil then
    FTiles.Sync(FForm, RootControl, FSelection.ToArray);
end;

{ message routing }

// CM_DESIGNHITTEST is the VCL pass-through contract: a control answering
// nonzero runs that mouse message itself, as a grid site does for its own
// design-time column drag.
function TFormDesigner.ControlClaimsMouse(Sender: TControl;
  const Message: TMessage): Boolean;
begin
  if (Message.Msg < WM_MOUSEMOVE) or (Message.Msg > WM_MBUTTONDBLCLK) or
    (FArmedItem <> nil) or (FDragKind <> dkNone) then
    Exit(False);
  Result := ((Sender is TWinControl) and TWinControl(Sender).HandleAllocated and
    (GetCapture = TWinControl(Sender).Handle)) or
    (Sender.Perform(CM_DESIGNHITTEST, Message.WParam, Message.LParam) <> 0);
end;

function TFormDesigner.IsDesignMsg(Sender: TControl; var Message: TMessage): Boolean;
var
  Target: TComponent;
begin
  Result := False;
  if FArmedItem <> nil then
  begin
    Result := CreationMsg(Sender, Message);
    if Result then
    begin
      Message.Result := 1;
      Exit;
    end;
  end;
  if ControlClaimsMouse(Sender, Message) then
    Exit;
  // Mouse and key input is swallowed rather than run by the designed control:
  // the event markers a load substitutes resolve to no user code. The
  // remaining arms only observe the message and pass it on.
  case Message.Msg of
    WM_LBUTTONDOWN:
      begin
        BeginMoveDrag(Sender);
        Result := True;
      end;
    WM_LBUTTONDBLCLK:
      begin
        RunDefaultComponentEditor;
        Result := True;
      end;
    WM_MOUSEMOVE:
      begin
        ContinueDrag;
        Result := True;
      end;
    WM_LBUTTONUP:
      begin
        EndDrag;
        Result := True;
      end;
    WM_RBUTTONDOWN:
      begin
        Target := ClickTarget(Sender);
        if not IsSelected(Target) then
          SelectComponent(Target);
        Result := True;
      end;
    WM_RBUTTONUP:
      begin
        RequestContextMenu;
        Result := True;
      end;
    WM_RBUTTONDBLCLK, WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK:
      Result := True;
    // Synthesized by the VCL on hover and capture changes; a control acting
    // on them can reset its stored Cursor and undo an inspector edit.
    CM_MOUSEENTER, CM_MOUSELEAVE:
      Result := True;
    WM_SETCURSOR:
      if Message.LParamLo = HTCLIENT then
      begin
        Winapi.Windows.SetCursor(Screen.Cursors[crArrow]);
        Result := True;
      end;
    CN_KEYDOWN, WM_KEYDOWN:
      Result := HandleKeyDown(TWMKey(Message).CharCode);
    CN_CHAR, WM_CHAR:
      Result := True;
    WM_SIZE:
      if (Sender = FForm) and (TComponent(FForm) = FRoot) then
        NoteFormSize(TWMSize(Message).Width, TWMSize(Message).Height);
    WM_ENTERSIZEMOVE:
      if (Sender = FForm) and (TComponent(FForm) = FRoot) then
        BeginSizeGesture;
    WM_EXITSIZEMOVE:
      if (Sender = FForm) and (TComponent(FForm) = FRoot) then
        EndSizeGesture;
  else
    Result := SwallowNonClient(Sender, Message);
  end;
  if Result then
    Message.Result := 1;
end;

function TFormDesigner.SwallowNonClient(Sender: TControl;
  var Message: TMessage): Boolean;
begin
  // The embedded root keeps its native frame for edge resizing; move, close
  // and maximize are swallowed here rather than by editing BorderIcons, which
  // is a stored property.
  Result := False;
  if Sender <> FForm then
    Exit;
  case Message.Msg of
    WM_NCLBUTTONDOWN, WM_NCLBUTTONDBLCLK:
      case Message.WParam of
        HTCAPTION:
          begin
            SelectComponent(FRoot);
            Result := True;
          end;
        HTSYSMENU, HTCLOSE, HTMINBUTTON, HTMAXBUTTON:
          Result := True;
      end;
    WM_CLOSE:
      Result := True;
    WM_SYSCOMMAND:
      case Message.WParam and $FFF0 of
        SC_CLOSE, SC_MINIMIZE, SC_MAXIMIZE, SC_MOVE, SC_RESTORE:
          Result := True;
      end;
  end;
end;

{ creation }

function TFormDesigner.CreationMsg(Sender: TControl; var Message: TMessage): Boolean;
begin
  Result := True;
  case Message.Msg of
    WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
      BeginCreateDrag(Sender);
    WM_MOUSEMOVE:
      ContinueCreateDrag;
    WM_LBUTTONUP:
      EndCreateDrag;
    // The right-button press is swallowed so the release that disarms the
    // placement selects nothing under the crosshair.
    WM_RBUTTONDOWN, WM_RBUTTONDBLCLK:
      ;
    WM_RBUTTONUP:
      DisarmCreation;
    WM_SETCURSOR:
      if Message.LParamLo = HTCLIENT then
        Winapi.Windows.SetCursor(Screen.Cursors[crCross])
      else
        Result := False;
    CN_KEYDOWN, WM_KEYDOWN:
      if TWMKey(Message).CharCode = VK_ESCAPE then
        DisarmCreation
      else
        Result := False;
  else
    Result := False;
  end;
end;

procedure TFormDesigner.ArmCreation(AItem: TPaletteItem);
begin
  if FGuarded then
    Exit;
  FArmedItem := AItem;
end;

procedure TFormDesigner.DisarmCreation;
begin
  if FArmedItem = nil then
    Exit;
  FArmedItem := nil;
  if FDragKind in [dkCreatePending, dkCreate] then
  begin
    ReleaseCapture;
    FDragFrame.Hide;
    FDragKind := dkNone;
  end;
  GestureEnded;
  if Assigned(FOnCreationFinished) then
    FOnCreationFinished(Self);
end;

procedure TFormDesigner.FocusSurface;
begin
  // Keyboard messages reach IsDesignMsg only through a focused design-mode
  // control; without focus on the hook host, arrows, Del and Esc go to the
  // shell.
  if (FForm <> nil) and FForm.HandleAllocated and not FForm.Focused then
    Winapi.Windows.SetFocus(FForm.Handle);
end;

procedure TFormDesigner.BeginCreateDrag(Sender: TControl);
var
  Anchor: TPoint;
  Reference: TWinControl;
begin
  if (FDragKind <> dkNone) or (FArmedItem = nil) then
    Exit;
  FocusSurface;
  if FArmedItem.IsNonVisual then
  begin
    FDragParent := nil;
    Reference := RootControl;
  end
  else
  begin
    FDragParent := AcceptingParent(Sender);
    Reference := FDragParent;
  end;
  if Reference = nil then
    Exit;
  GetCursorPos(FDragAnchor);
  Anchor := Reference.ScreenToClient(FDragAnchor);
  FDragOrigin := TRect.Create(Anchor, 0, 0);
  FDragRect := FDragOrigin;
  FDragKind := dkCreatePending;
  SetCapture(FForm.Handle);
end;

procedure TFormDesigner.ContinueCreateDrag;
var
  CursorPos: TPoint;
begin
  if not (FDragKind in [dkCreatePending, dkCreate]) then
    Exit;
  if (FArmedItem = nil) or FArmedItem.IsNonVisual then
    Exit;
  GetCursorPos(CursorPos);
  if FDragKind = dkCreatePending then
  begin
    if (Abs(CursorPos.X - FDragAnchor.X) < DragThreshold) and
       (Abs(CursorPos.Y - FDragAnchor.Y) < DragThreshold) then
      Exit;
    FDragKind := dkCreate;
  end;
  FDragRect := ComputeCreateRect(CursorPos);
  ShowDragFrame;
end;

procedure TFormDesigner.EndCreateDrag;
var
  Sized: Boolean;
  Item: TPaletteItem;
begin
  if not (FDragKind in [dkCreatePending, dkCreate]) then
    Exit;
  Sized := FDragKind = dkCreate;
  ReleaseCapture;
  FDragFrame.Hide;
  FDragKind := dkNone;
  Item := FArmedItem;
  if Item <> nil then
    if Item.IsNonVisual then
      PlaceNonVisual(Item, Snap(FDragOrigin.Left), Snap(FDragOrigin.Top))
    else if Sized then
      PlaceControl(Item, FDragParent, FDragRect, pmSizedRect)
    else
      PlaceControl(Item, FDragParent,
        TRect.Create(Point(Snap(FDragOrigin.Left), Snap(FDragOrigin.Top)), 0, 0),
        pmDefaultSize);
  DisarmCreation;
end;

procedure TFormDesigner.PlaceArmedAt(X, Y: Integer);
var
  Item: TPaletteItem;
begin
  Item := FArmedItem;
  if Item = nil then
    Exit;
  if Item.IsNonVisual then
    PlaceNonVisual(Item, Snap(X), Snap(Y))
  else if FLog <> nil then
    FLog.AddFmt(lsWarn, '%s is a control and cannot be placed on a data ' +
      'module - a data module holds nonvisual components only',
      [Item.ComponentClass.ClassName]);
  DisarmCreation;
end;

procedure TFormDesigner.CreateCentered(AItem: TPaletteItem);
var
  Area: TRect;
begin
  if (AItem = nil) or FGuarded then
    Exit;
  if AItem.IsNonVisual then
  begin
    Area := TRect.Empty;
    if FSurfaceControl <> nil then
      Area := FSurfaceControl.ClientRect;
    PlaceNonVisual(AItem, Snap((Area.Width - TileGlyphSize) div 2),
      Snap((Area.Height - TileGlyphSize) div 2));
  end
  else if RootControl <> nil then
    PlaceControl(AItem, RootControl, TRect.Empty, pmCentered)
  else if FLog <> nil then
    FLog.AddFmt(lsWarn, '%s is a control and cannot be placed on a data ' +
      'module - a data module holds nonvisual components only',
      [AItem.ComponentClass.ClassName]);
  DisarmCreation;
end;

function TFormDesigner.ComputeCreateRect(const CursorPos: TPoint): TRect;
var
  Corner: TPoint;
begin
  Corner := FDragParent.ScreenToClient(CursorPos);
  Result := TRect.Create(Point(Snap(FDragOrigin.Left), Snap(FDragOrigin.Top)),
    Point(Snap(Corner.X), Snap(Corner.Y)), True);
end;

function TFormDesigner.AcceptingParent(AControl: TControl): TWinControl;
begin
  // csAcceptsControls is advisory in the VCL, so the drop target is walked up
  // to the nearest container. Frame interiors are skipped: their contents
  // belong to the frame's own file.
  Result := RootControl;
  while AControl <> nil do
  begin
    if (AControl is TWinControl) and
       (csAcceptsControls in AControl.ControlStyle) and
       not BelongsToFrame(AControl) then
      Exit(TWinControl(AControl));
    AControl := AControl.Parent;
  end;
end;

procedure TFormDesigner.FinishCreation(AComponent: TComponent; const AWhere: string);
begin
  if FLog <> nil then
    FLog.AddFmt(lsInfo, 'created %s: %s in %s',
      [AComponent.Name, AComponent.ClassName, AWhere]);
  SelectComponent(AComponent);
  InvalidateSurface;
  StructureChanged;
  Modified;
end;

function TFormDesigner.PlaceControl(AItem: TPaletteItem; AParent: TWinControl;
  const ABounds: TRect; AMode: TPlacementMode): TControl;
var
  NewControl: TControl;
  Placement: TRect;
begin
  Result := nil;
  if (AItem = nil) or (AParent = nil) then
    Exit;
  NewControl := nil;
  PushUndo(uoCreate);
  try
    NewControl := AItem.ControlClass.Create(FRoot);
    NewControl.Name := UniqueName(AItem.DisplayName);
    NewControl.Parent := AParent;
    Placement := ABounds;
    case AMode of
      pmDefaultSize:
        Placement := TRect.Create(ABounds.TopLeft, NewControl.Width,
          NewControl.Height);
      pmSizedRect:
        begin
          if Placement.Width < MinimumCreateSize then
            Placement.Width := MinimumCreateSize;
          if Placement.Height < MinimumCreateSize then
            Placement.Height := MinimumCreateSize;
        end;
      pmCentered:
        Placement := TRect.Create(
          Point((AParent.ClientWidth - NewControl.Width) div 2,
            (AParent.ClientHeight - NewControl.Height) div 2),
          NewControl.Width, NewControl.Height);
    end;
    NewControl.SetBounds(Placement.Left, Placement.Top, Placement.Width,
      Placement.Height);
  except
    on E: Exception do
    begin
      NewControl.Free;
      DropUndo;
      if FLog <> nil then
        FLog.AddFmt(lsError, 'creating a %s failed: %s',
          [AItem.ComponentClass.ClassName, E.Message]);
      Exit;
    end;
  end;
  Result := NewControl;
  FinishCreation(NewControl, AParent.Name);
end;

function TFormDesigner.PlaceNonVisual(AItem: TPaletteItem; X, Y: Integer): TComponent;
var
  NewComponent: TComponent;
begin
  Result := nil;
  if AItem = nil then
    Exit;
  NewComponent := nil;
  PushUndo(uoCreate);
  try
    NewComponent := AItem.ComponentClass.Create(FRoot);
    NewComponent.Name := UniqueName(AItem.DisplayName);
    SetTilePosition(NewComponent, X, Y);
  except
    on E: Exception do
    begin
      NewComponent.Free;
      DropUndo;
      if FLog <> nil then
        FLog.AddFmt(lsError, 'creating a %s failed: %s',
          [AItem.ComponentClass.ClassName, E.Message]);
      Exit;
    end;
  end;
  Result := NewComponent;
  FinishCreation(NewComponent, FRoot.Name);
end;

{ input }

function TFormDesigner.BelongsToDocument(AControl: TControl): Boolean;
var
  Owner: TComponent;
begin
  if IsPlaceholder(AControl) then
    Exit(True);
  Owner := AControl.Owner;
  while (Owner <> nil) and (Owner <> FRoot) and
    (csInline in Owner.ComponentState) do
    Owner := Owner.Owner;
  Result := Owner = FRoot;
end;

function TFormDesigner.DeepestDesignedAt(AFrom: TControl;
  const AScreen: TPoint): TControl;
var
  Child: TControl;
begin
  Result := AFrom;
  while Result is TWinControl do
  begin
    Child := TWinControl(Result).ControlAtPos(
      TWinControl(Result).ScreenToClient(AScreen), True, True, False);
    if (Child = nil) or not BelongsToDocument(Child) then
      Break;
    Result := Child;
  end;
end;

function TFormDesigner.ClickTarget(Sender: TControl): TComponent;
var
  Surface: TWinControl;
  Where: TPoint;
  Tile: TComponent;
  Anchor: TControl;
begin
  Result := Sender;
  Surface := RootControl;
  if Surface = nil then
    Exit;
  GetCursorPos(Where);
  // Tiles are tested first whatever the click arrived at: they are drawn over
  // every designed control, and the layer showing them takes no mouse input
  // of its own.
  Tile := TileAt(FRoot, Surface.ScreenToClient(Where));
  if Tile <> nil then
    Exit(Tile);
  if (Sender = Surface) or (Sender = FForm) then
    Anchor := Surface
  else
  begin
    // A message can arrive at an inner window a designed control creates for
    // itself, e.g. a grid's view site; the anchor is the nearest designed
    // parent.
    Anchor := Sender;
    while (Anchor <> nil) and (TComponent(Anchor) <> FRoot) and
      not BelongsToDocument(Anchor) do
      Anchor := Anchor.Parent;
    if Anchor = nil then
      Exit(FRoot);
  end;
  // A control disabled at design time (csNeedsDesignDisabledState) never
  // receives the click: Windows delivers it to the container, so only
  // geometry finds the intended control.
  Result := DeepestDesignedAt(Anchor, Where);
end;

procedure TFormDesigner.BeginMoveDrag(Sender: TControl);
var
  Target: TComponent;
begin
  if FDragKind <> dkNone then
    Exit;
  FocusSurface;
  Target := ClickTarget(Sender);
  if ssShift in KeyboardStateToShiftState then
  begin
    ToggleSelection(Target);
    Exit;
  end;
  if Target = FRoot then
  begin
    SelectComponent(FRoot);
    BeginMarquee;
    Exit;
  end;
  if IsSelected(Target) then
    MakePrimary(Target)
  else
    SelectComponent(Target);
  if (FSelected = FRoot) or IsPlaceholder(FSelected) or FGuarded then
    Exit;
  FDragKind := dkPending;
  FResizeHandle := hkTopLeft;
  GetCursorPos(FDragAnchor);
  if FSelected is TControl then
  begin
    FDragOrigin := TControl(FSelected).BoundsRect;
    FDragParent := TControl(FSelected).Parent;
  end
  else
  begin
    FDragOrigin := TileGlyphBounds(FSelected);
    FDragParent := RootControl;
  end;
  FDragRect := FDragOrigin;
  // Captured on the host so moves outside the clicked control still reach
  // IsDesignMsg.
  SetCapture(FForm.Handle);
end;

procedure TFormDesigner.HandleDrag(Kind: THandleKind; Stage: THandleDragStage);
begin
  // A resize gesture runs on the handle window's own mouse capture, so its
  // messages arrive here instead of through IsDesignMsg.
  case Stage of
    hdsBegin:
      begin
        if not (FSelected is TControl) or (FDragKind <> dkNone) or
           FGuarded then
          Exit;
        FDragKind := dkResize;
        FResizeHandle := Kind;
        GetCursorPos(FDragAnchor);
        FDragOrigin := TControl(FSelected).BoundsRect;
        FDragRect := FDragOrigin;
        FDragParent := TControl(FSelected).Parent;
        ShowDragFrame;
      end;
    hdsMove:
      if FDragKind = dkResize then
        ContinueDrag;
    hdsEnd:
      if FDragKind = dkResize then
        EndDrag;
  end;
end;

procedure TFormDesigner.BeginMarquee;
var
  Reference: TWinControl;
  Anchor: TPoint;
begin
  Reference := RootControl;
  if (Reference = nil) or (FForm = nil) then
    Exit;
  GetCursorPos(FDragAnchor);
  Anchor := Reference.ScreenToClient(FDragAnchor);
  FDragParent := Reference;
  FDragOrigin := TRect.Create(Anchor, 0, 0);
  FDragRect := FDragOrigin;
  FDragKind := dkMarqueePending;
  SetCapture(FForm.Handle);
end;

function TFormDesigner.ComputeMarqueeRect(const CursorPos: TPoint): TRect;
var
  Corner: TPoint;
begin
  Corner := FDragParent.ScreenToClient(CursorPos);
  Result := TRect.Create(FDragOrigin.TopLeft, Corner, True);
end;

procedure TFormDesigner.CommitMarquee;
var
  Root: TWinControl;
  I: Integer;
  Control: TControl;
  Component: TComponent;
  Hits: TArray<TComponent>;
begin
  Root := RootControl;
  if Root = nil then
    Exit;
  for I := 0 to Root.ControlCount - 1 do
  begin
    Control := Root.Controls[I];
    // Chrome controls are parented here but ownerless; placeholders are
    // ownerless too, yet stand for real file content and stay selectable.
    if ((Control.Owner = FRoot) or IsPlaceholder(Control)) and
      FDragRect.IntersectsWith(Control.BoundsRect) then
      Hits := Hits + [Control];
  end;
  for I := 0 to FRoot.ComponentCount - 1 do
  begin
    Component := FRoot.Components[I];
    if IsNonVisual(Component) and
      FDragRect.IntersectsWith(TileGlyphBounds(Component)) then
      Hits := Hits + [Component];
  end;
  SelectMany(Hits);
end;

procedure TFormDesigner.ContinueDrag;
var
  CursorPos: TPoint;
begin
  if FDragKind = dkNone then
    Exit;
  GetCursorPos(CursorPos);
  if FDragKind in [dkPending, dkMarqueePending] then
  begin
    if (Abs(CursorPos.X - FDragAnchor.X) < DragThreshold) and
       (Abs(CursorPos.Y - FDragAnchor.Y) < DragThreshold) then
      Exit;
    if FDragKind = dkPending then
      FDragKind := dkMove
    else
      FDragKind := dkMarquee;
  end;
  if FDragKind = dkMarquee then
    FDragRect := ComputeMarqueeRect(CursorPos)
  else
    FDragRect := ComputeDragRect(CursorPos);
  ShowDragFrame;
end;

procedure TFormDesigner.EndDrag;
var
  Kind: TDragKind;
begin
  if FDragKind = dkNone then
    Exit;
  if FDragKind <> dkResize then
    ReleaseCapture;
  FDragFrame.Hide;
  Kind := FDragKind;
  // FDragKind is cleared even when committing raises: applying bounds runs
  // the control's own OnResize, and a gesture left in flight would block undo
  // and settling for the rest of this document's life.
  try
    if Kind = dkMarquee then
      CommitMarquee
    else if Kind in [dkMove, dkResize] then
      CommitDrag;
  finally
    FDragKind := dkNone;
    GestureEnded;
  end;
end;

function TFormDesigner.HandleKeyDown(CharCode: Word): Boolean;
var
  Shift: TShiftState;
begin
  Result := True;
  Shift := KeyboardStateToShiftState;
  case CharCode of
    VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN:
      NudgeSelection(CharCode, Shift);
    VK_ESCAPE:
      if FDragKind <> dkNone then
        CancelDrag
      else
        SelectParent;
    VK_DELETE:
      DeleteSelection;
    Ord('S'):
      if ssCtrl in Shift then
        RequestSave;
    Ord('C'):
      if ssCtrl in Shift then
        CopySelection;
    Ord('X'):
      if ssCtrl in Shift then
        CutSelection;
    Ord('V'):
      if ssCtrl in Shift then
        PasteFromClipboard;
    Ord('Z'):
      if ssCtrl in Shift then
        RequestUndo;
    Ord('Y'):
      if ssCtrl in Shift then
        RequestRedo;
  end;
end;

procedure TFormDesigner.RequestSave;
begin
  if Assigned(FOnSaveRequest) then
    FOnSaveRequest(Self)
  else
    Save;
end;

// Windows' modal sizing loop pumps this thread's messages, so deferred calls
// are delivered mid-gesture; FSizeGestureRunning covers that loop.
function TFormDesigner.GestureInFlight: Boolean;
begin
  Result := (FDragKind <> dkNone) or FExternalGesture or FSizeGestureRunning;
end;

procedure TFormDesigner.SetExternalGesture(AValue: Boolean);
begin
  if FExternalGesture = AValue then
    Exit;
  FExternalGesture := AValue;
  if not AValue then
    GestureEnded;
end;

procedure TFormDesigner.RequestUndo;
begin
  if not GestureInFlight and Assigned(FOnUndoRequest) then
    FOnUndoRequest(Self);
end;

procedure TFormDesigner.RequestRedo;
begin
  if not GestureInFlight and Assigned(FOnRedoRequest) then
    FOnRedoRequest(Self);
end;

procedure TFormDesigner.NudgeSelection(CharCode: Word; Shift: TShiftState);
var
  Step, DX, DY: Integer;
  Position: TPoint;
  Target: TControl;
  Item: TComponent;
begin
  if (FDragKind <> dkNone) or IsPlaceholder(FSelected) or FGuarded then
    Exit;
  if (ssShift in Shift) or (ssCtrl in Shift) then
    Step := 1
  else
    Step := FGridSize;
  DX := 0;
  DY := 0;
  case CharCode of
    VK_LEFT: DX := -Step;
    VK_RIGHT: DX := Step;
    VK_UP: DY := -Step;
    VK_DOWN: DY := Step;
  end;

  if ssShift in Shift then
  begin
    if not (FSelected is TControl) then
      Exit;
    if (FSelected = FRoot) and (FSelected is TCustomForm) then
      Exit;
    Target := TControl(FSelected);
    PushUndo(uoNudge);
    ApplyBounds(Target, Target.Left, Target.Top, Target.Width + DX,
      Target.Height + DY);
    Exit;
  end;

  if (FSelection.Count = 1) and (FSelected = FRoot) then
    Exit;
  PushUndo(uoNudge);
  for Item in FSelection do
  begin
    if (Item = FRoot) or IsPlaceholder(Item) then
      Continue;
    if Item is TControl then
    begin
      Target := TControl(Item);
      ApplyBounds(Target, Target.Left + DX, Target.Top + DY, Target.Width,
        Target.Height);
    end
    else if IsNonVisual(Item) then
    begin
      Position := TilePosition(Item);
      MoveTile(Item, Position.X + DX, Position.Y + DY);
    end;
  end;
  UpdateHandles;
end;

procedure CollectNames(AComponent: TComponent; var ANames: TArray<string>);
var
  I: Integer;
  Container: TWinControl;
begin
  if AComponent.Name <> '' then
    ANames := ANames + [AComponent.Name];
  if not (AComponent is TWinControl) then
    Exit;
  Container := TWinControl(AComponent);
  for I := 0 to Container.ControlCount - 1 do
    CollectNames(Container.Controls[I], ANames);
end;

// Placeholders inside the container are released first: the container frees
// its child controls on destruction, and the placeholders are not its to free.
procedure TFormDesigner.DropPreservedIn(AComponent: TComponent);
var
  Names: TArray<string>;
begin
  if FPreserved = nil then
    Exit;
  if AComponent is TWinControl then
    FPreserved.ReleasePlaceholdersIn(TWinControl(AComponent));
  CollectNames(AComponent, Names);
  FPreserved.DropOwnedBy(Names);
end;

// Recurses into containers: a save looks up every listed frame instance by
// name and raises for one that is no longer in the document.
procedure TFormDesigner.ForgetFramesIn(AComponent: TComponent);
var
  I: Integer;
  Container: TWinControl;
begin
  if FFrames = nil then
    Exit;
  FFrames.Forget(AComponent);
  if not (AComponent is TWinControl) then
    Exit;
  Container := TWinControl(AComponent);
  for I := 0 to Container.ControlCount - 1 do
    ForgetFramesIn(Container.Controls[I]);
end;

procedure TFormDesigner.DeletePlaceholder(APiece: TPreservedPiece);
var
  Description: string;
begin
  if FGuarded then
    Exit;
  Description := APiece.Describe;
  if MessageDlg(Format('Delete %s?'#13#10#13#10 +
    'The designer cannot read this one and keeps it exactly as it found it. ' +
    'Deleting it drops those lines from the file.', [Description]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  PushUndo(uoDelete);
  SelectComponent(FRoot);
  if FLog <> nil then
    FLog.AddFmt(lsInfo, 'dropped the preserved text of %s', [Description]);
  FPreserved.DropPiece(APiece);
  Modified;
  InvalidateSurface;
  StructureChanged;
end;

// True when AComponent is a control parented, directly or indirectly, by
// another entry of AList.
function SitsInsideAny(AComponent: TComponent; const AList: TArray<TComponent>): Boolean;
var
  Parent: TWinControl;
  Other: TComponent;
begin
  if not (AComponent is TControl) then
    Exit(False);
  Parent := TControl(AComponent).Parent;
  while Parent <> nil do
  begin
    for Other in AList do
      if TComponent(Parent) = Other then
        Exit(True);
    Parent := Parent.Parent;
  end;
  Result := False;
end;

procedure TFormDesigner.DeleteSelection;
var
  Selected, Doomed, Outermost: TArray<TComponent>;
  Item: TComponent;
  Frozen, InFrames, Inherited_: Integer;
  InheritedNames: string;
begin
  if (FDragKind <> dkNone) or FGuarded then
    Exit;
  if (FSelection.Count = 1) and IsPlaceholder(FSelected) then
  begin
    DeletePlaceholder(PlaceholderPiece(FSelected));
    Exit;
  end;
  Selected := SelectedInstances;
  InFrames := 0;
  Inherited_ := 0;
  InheritedNames := '';
  for Item in Selected do
    if FrameInstanceHolding(Item) <> nil then
      Inc(InFrames)
    else if IsInherited(Item) then
    begin
      Inc(Inherited_);
      if InheritedNames <> '' then
        InheritedNames := InheritedNames + ', ';
      InheritedNames := InheritedNames + Item.Name;
    end
    else if (Item <> FRoot) and not IsPlaceholder(Item) then
      Doomed := Doomed + [Item];
  if (FLog <> nil) and (InFrames > 0) then
    FLog.AddFmt(lsWarn, '%d component(s) inside a frame were not deleted - ' +
      'frame contents belong to the frame''s own file', [InFrames]);
  if (FLog <> nil) and (Inherited_ = 1) then
    FLog.AddFmt(lsWarn, '%s was not deleted - it is inherited from %s; open ' +
      'that form to delete it', [InheritedNames, FAncestor.Root.ClassName])
  else if (FLog <> nil) and (Inherited_ > 1) then
    FLog.AddFmt(lsWarn, '%s were not deleted - they are inherited from %s; ' +
      'open that form to delete them', [InheritedNames, FAncestor.Root.ClassName]);
  for Item in Doomed do
    if not SitsInsideAny(Item, Doomed) then
      Outermost := Outermost + [Item];
  Doomed := Outermost;
  Frozen := 0;
  for Item in Selected do
    if IsPlaceholder(Item) and not SitsInsideAny(Item, Doomed) then
      Inc(Frozen);
  if (FLog <> nil) and (Frozen > 0) then
    FLog.AddFmt(lsWarn, '%d component(s) kept as found were not deleted - ' +
      'delete one individually to drop its preserved text', [Frozen]);
  if Length(Doomed) = 0 then
    Exit;
  PushUndo(uoDelete);
  SelectComponent(FRoot);
  for Item in Doomed do
  begin
    DropPreservedIn(Item);
    ForgetFramesIn(Item);
    if FLog <> nil then
      FLog.AddFmt(lsInfo, 'deleted %s', [Item.Name]);
    // Design windows watching the component are closed before it is freed.
    if FHostDesigner <> nil then
      NotifyItemDeleted(FHostDesigner, Item);
    Item.Free;
  end;
  Modified;
  InvalidateSurface;
  StructureChanged;
end;

{ clipboard }

function ListHolds(const AList: TArray<TComponent>;
  AComponent: TComponent): Boolean;
var
  Present: TComponent;
begin
  for Present in AList do
    if Present = AComponent then
      Exit(True);
  Result := False;
end;

function NameStem(const AName: string): string;
var
  Last: Integer;
begin
  Last := Length(AName);
  while (Last > 1) and CharInSet(AName[Last], ['0' .. '9']) do
    Dec(Last);
  Result := Copy(AName, 1, Last);
end;

// OpenClipboard fails with ERROR_ACCESS_DENIED while another process holds
// the clipboard, which a clipboard watcher does after every change.
function ClipboardAttempt(const AAction: TProc): Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to ClipboardAttempts do
    try
      AAction;
      Exit(True);
    except
      on EClipboardException do
        if Attempt < ClipboardAttempts then
          Sleep(ClipboardRetryDelay);
    end;
  Result := False;
end;

function PutClipboardText(const AText: string): Boolean;
begin
  Result := ClipboardAttempt(
    procedure
    begin
      Clipboard.AsText := AText;
    end);
end;

function TFormDesigner.CanCopySelection: Boolean;
var
  Item: TComponent;
begin
  Result := False;
  for Item in FSelection do
    if (Item <> FRoot) and not IsPlaceholder(Item) and
       not BelongsToFrame(Item) then
      Exit(True);
end;

// Document order rather than selection order, so a paste reproduces the
// creation order the file holds.
function TFormDesigner.CopyableSelection: TArray<TComponent>;
var
  Selected, Candidates: TArray<TComponent>;
  Item: TComponent;
  I, Frozen, InFrames: Integer;
begin
  Result := nil;
  Candidates := nil;
  Frozen := 0;
  InFrames := 0;
  Selected := SelectedInstances;
  for Item in Selected do
    if Item = FRoot then
      Continue
    else if IsPlaceholder(Item) then
      Inc(Frozen)
    else if BelongsToFrame(Item) then
      Inc(InFrames)
    else
      Candidates := Candidates + [Item];
  if (FLog <> nil) and (Frozen > 0) then
    FLog.AddFmt(lsWarn, '%d component(s) kept as found were not copied - the ' +
      'text they stand for belongs to the file it was read from', [Frozen]);
  if (FLog <> nil) and (InFrames > 0) then
    FLog.AddFmt(lsWarn, '%d component(s) of a frame were not copied - frame ' +
      'contents belong to the frame''s own file', [InFrames]);
  for I := 0 to FRoot.ComponentCount - 1 do
    if ListHolds(Candidates, FRoot.Components[I]) and
       not SitsInsideAny(FRoot.Components[I], Candidates) then
      Result := Result + [FRoot.Components[I]];
end;

function TFormDesigner.SelectionAsFragment: string;
var
  Copied: TArray<TComponent>;
begin
  Result := '';
  if FDragKind <> dkNone then
    Exit;
  Copied := CopyableSelection;
  if Length(Copied) = 0 then
  begin
    if FLog <> nil then
      FLog.Add(lsWarn, 'nothing in the selection can be copied');
    Exit;
  end;
  SinkChrome;
  try
    Result := WriteComponentFragment(Copied, FRoot, FEventMap);
  except
    on E: Exception do
    begin
      Result := '';
      if FLog <> nil then
        FLog.AddFmt(lsError, 'copying failed: %s', [E.Message]);
    end;
  end;
end;

function TFormDesigner.WriteSelectionToClipboard: Boolean;
var
  Text: string;
begin
  Text := SelectionAsFragment;
  Result := (Text <> '') and PutClipboardText(Text);
  if not Result then
  begin
    if (Text <> '') and (FLog <> nil) then
      FLog.Add(lsError, 'the clipboard is held by another program and could ' +
        'not be written');
    Exit;
  end;
  if FLog <> nil then
    FLog.Add(lsInfo, 'the selection was copied to the clipboard');
end;

procedure TFormDesigner.CopySelection;
begin
  WriteSelectionToClipboard;
end;

procedure TFormDesigner.CutSelection;
begin
  if FGuarded or (FDragKind <> dkNone) then
    Exit;
  if WriteSelectionToClipboard then
    DeleteSelection;
end;

function TFormDesigner.ClipboardText(out AText: string): Boolean;
var
  Held: string;
begin
  AText := '';
  if not Clipboard.HasFormat(CF_UNICODETEXT) then
    Exit(True);
  Result := ClipboardAttempt(
    procedure
    begin
      Held := Clipboard.AsText;
    end);
  if Result then
    AText := Held;
end;

function TFormDesigner.ClipboardFragment(out AText: string): Boolean;
begin
  Result := ClipboardText(AText) and StartsWithBlockKeyword(AText);
end;

// A failed read does not move FClipboardSequence, so the next idle-time
// update reads again instead of keeping the refusal until the clipboard
// changes.
function TFormDesigner.CanPaste: Boolean;
var
  Sequence: Cardinal;
  Text: string;
begin
  Result := False;
  if FGuarded or (FDragKind <> dkNone) then
    Exit;
  Sequence := GetClipboardSequenceNumber;
  if (Sequence <> FClipboardSequence) and ClipboardText(Text) then
  begin
    FClipboardSequence := Sequence;
    FClipboardPastable := StartsWithBlockKeyword(Text);
  end;
  Result := FClipboardPastable;
end;

function TFormDesigner.PasteTarget: TWinControl;
begin
  Result := RootControl;
  if (Result <> nil) and (FSelected is TControl) and
     not IsPlaceholder(FSelected) then
    Result := AcceptingParent(TControl(FSelected));
end;

function TFormDesigner.PasteName(const AName: string): string;
begin
  Result := AName;
  if AName = '' then
    Exit;
  if (FRoot.FindComponent(AName) = nil) and
     ((FPreserved = nil) or not FPreserved.IsReservedName(AName)) then
    Exit;
  Result := UniqueName(NameStem(AName));
end;

procedure TFormDesigner.PasteHandlerName(const AOldComponent, ANewComponent,
  AEvent: string; var AMethod: string);
begin
  if SameText(AOldComponent, ANewComponent) or
     not SameText(AMethod, DefaultHandlerName(AOldComponent, AEvent)) then
    Exit;
  if not CodeCouplingAvailable then
    raise EComponentFragmentError.CreateFmt('pasting %s renames its handler ' +
      '%s, and that method has to be added to the unit beside this document ' +
      '- no editor is attached to it', [AOldComponent, AMethod]);
  AMethod := DefaultHandlerName(ANewComponent, AEvent);
end;

procedure TFormDesigner.OffsetPasted(const AComponents: TArray<TComponent>);

  function ControlIsCovered(AControl: TControl): Boolean;
  var
    Parent: TWinControl;
    I: Integer;
  begin
    Result := False;
    Parent := AControl.Parent;
    if Parent = nil then
      Exit;
    for I := 0 to Parent.ControlCount - 1 do
      if (Parent.Controls[I] <> AControl) and
         not ListHolds(AComponents, Parent.Controls[I]) and
         (Parent.Controls[I].BoundsRect = AControl.BoundsRect) then
        Exit(True);
  end;

  function TileIsCovered(AComponent: TComponent): Boolean;
  var
    I: Integer;
    Other: TComponent;
  begin
    Result := False;
    for I := 0 to FRoot.ComponentCount - 1 do
    begin
      Other := FRoot.Components[I];
      if (Other <> AComponent) and IsNonVisual(Other) and
         not ListHolds(AComponents, Other) and
         (TilePosition(Other) = TilePosition(AComponent)) then
        Exit(True);
    end;
  end;

  function AnythingIsCovered: Boolean;
  var
    Item: TComponent;
  begin
    Result := False;
    for Item in AComponents do
      if IsNonVisual(Item) then
      begin
        if TileIsCovered(Item) then
          Exit(True);
      end
      else if (Item is TControl) and ControlIsCovered(TControl(Item)) then
        Exit(True);
  end;

  // A step that moves nothing ends the loop: an aligned control takes its
  // position from its parent and refuses the offset every time.
  function StepAside(AStep: Integer): Boolean;
  var
    Item: TComponent;
    Control: TControl;
    Position: TPoint;
  begin
    Result := False;
    for Item in AComponents do
      if IsNonVisual(Item) then
      begin
        Position := TilePosition(Item);
        SetTilePosition(Item, Position.X + AStep, Position.Y + AStep);
        Result := Result or (TilePosition(Item) <> Position);
      end
      else if Item is TControl then
      begin
        Control := TControl(Item);
        Position := Point(Control.Left, Control.Top);
        Control.SetBounds(Control.Left + AStep, Control.Top + AStep,
          Control.Width, Control.Height);
        Result := Result or (Control.Left <> Position.X) or
          (Control.Top <> Position.Y);
      end;
  end;

var
  Step, Steps: Integer;
begin
  Step := FGridSize;
  if Step < 1 then
    Step := 1;
  Steps := 0;
  while (Steps < MaxPasteOffsets) and AnythingIsCovered do
  begin
    if not StepAside(Step) then
      Break;
    Inc(Steps);
  end;
end;

procedure TFormDesigner.RequestPastedHandlers(
  const AHandlers: TArray<TFragmentHandler>);
var
  Entry: TFragmentHandler;
  Target: TComponent;
  Info: PPropInfo;
begin
  if FCodeCoupling = nil then
    Exit;
  for Entry in AHandlers do
  begin
    Target := FRoot.FindComponent(Entry.Component);
    if Target = nil then
      Continue;
    Info := GetPropInfo(Target, Entry.Event, [tkMethod]);
    if Info = nil then
      Continue;
    FCodeCoupling.EnsureHandler(Entry.Component, Entry.Event, Entry.Method,
      SignatureOf(Info^.PropType^));
  end;
end;

procedure TFormDesigner.PasteFromClipboard;
var
  Text: string;
begin
  if not ClipboardFragment(Text) then
  begin
    if FLog <> nil then
      FLog.Add(lsWarn, 'the clipboard holds no component block to paste');
    Exit;
  end;
  PasteFragment(Text);
end;

procedure TFormDesigner.PasteFragment(const AText: string);
var
  Target: TWinControl;
  Reader: TFragmentReader;
  Pasted: TArray<TComponent>;
  Handlers: TArray<TFragmentHandler>;
  Item: TComponent;
  Failed: Boolean;
begin
  if FGuarded or (FDragKind <> dkNone) then
    Exit;
  if FEventMap = nil then
  begin
    if FLog <> nil then
      FLog.Add(lsError, 'this document has no event map, so nothing can be ' +
        'pasted into it');
    Exit;
  end;
  Target := PasteTarget;
  Failed := False;
  Pasted := nil;
  Handlers := nil;
  Reader := TFragmentReader.Create(FRoot, FEventMap);
  try
    Reader.OnNaming := PasteName;
    Reader.OnHandlerNaming := PasteHandlerName;
    PushUndo(uoCreate);
    try
      Pasted := Reader.Read(AText, Target);
      Handlers := Reader.Handlers;
    except
      on E: Exception do
      begin
        DropUndo;
        Failed := True;
        if FLog <> nil then
          FLog.AddFmt(lsError, 'pasting failed: %s', [E.Message]);
      end;
    end;
  finally
    Reader.Free;
  end;
  if Failed then
    Exit;
  if Length(Pasted) = 0 then
  begin
    DropUndo;
    Exit;
  end;
  OffsetPasted(Pasted);
  RequestPastedHandlers(Handlers);
  if FLog <> nil then
    for Item in Pasted do
      FLog.AddFmt(lsInfo, 'pasted %s: %s', [Item.Name, Item.ClassName]);
  SelectMany(Pasted);
  InvalidateSurface;
  StructureChanged;
  Modified;
end;

procedure TFormDesigner.UpdateHandles;
begin
  UpdateTiles;
  if (FSelected is TControl) and not (FSelected is TCustomForm) and
    not IsPlaceholder(FSelected) then
    FHandles.ShowFor(FSelected)
  else
    FHandles.ShowFor(nil);
  UpdateOutlines;
end;

procedure TFormDesigner.UpdateOutlines;
var
  Item: TComponent;
  Control: TControl;
  Outline: TDragFrame;
begin
  FOutlines.Clear;
  if FSelection.Count < 2 then
    Exit;
  for Item in FSelection do
  begin
    if (Item = FSelected) or not (Item is TControl) then
      Continue;
    Control := TControl(Item);
    if Control.Parent = nil then
      Continue;
    Outline := TDragFrame.Create;
    Outline.Chrome := FForm;
    FOutlines.Add(Outline);
    Outline.ShowRect(Control.Parent, Control.BoundsRect);
  end;
end;

procedure TFormDesigner.SelectComponent(AComponent: TComponent);
var
  Previous: TComponent;
  WasGroup: Boolean;
begin
  if (AComponent = nil) or (TComponent(FForm) = AComponent) then
    AComponent := FRoot;
  Previous := FSelected;
  WasGroup := FSelection.Count > 1;
  FSelection.Clear;
  FSelection.Add(AComponent);
  FSelected := AComponent;
  UpdateHandles;
  // Re-selecting the same component still notifies while an auxiliary
  // selection stands: a closing collection editor selects it that way.
  if (Previous = AComponent) and not WasGroup and (Length(FAuxSelection) = 0) then
    Exit;
  if WasGroup or IsNonVisual(Previous) or IsNonVisual(FSelected) then
    InvalidateSurface;
  SurfaceSelectionChanged;
end;

procedure TFormDesigner.ToggleSelection(AComponent: TComponent);
var
  Index: Integer;
begin
  if (AComponent = nil) or (AComponent = FRoot) or
    (TComponent(FForm) = AComponent) then
    Exit;
  Index := FSelection.IndexOf(AComponent);
  if Index >= 0 then
  begin
    FSelection.Delete(Index);
    if FSelection.Count = 0 then
      FSelection.Add(FRoot);
  end
  else
  begin
    if (FSelection.Count = 1) and (FSelection[0] = FRoot) then
      FSelection.Clear;
    FSelection.Add(AComponent);
  end;
  FSelected := FSelection.Last;
  UpdateHandles;
  InvalidateSurface;
  SurfaceSelectionChanged;
end;

procedure TFormDesigner.SelectMany(const AComponents: TArray<TComponent>);
var
  Component: TComponent;
begin
  if Length(AComponents) = 0 then
  begin
    SelectComponent(FRoot);
    Exit;
  end;
  FSelection.Clear;
  for Component in AComponents do
    if (Component <> FRoot) and (FSelection.IndexOf(Component) < 0) then
      FSelection.Add(Component);
  if FSelection.Count = 0 then
    FSelection.Add(FRoot);
  FSelected := FSelection.Last;
  UpdateHandles;
  InvalidateSurface;
  SurfaceSelectionChanged;
end;

procedure TFormDesigner.MakePrimary(AComponent: TComponent);
begin
  if (AComponent = FSelected) or (FSelection.IndexOf(AComponent) < 0) then
    Exit;
  FSelected := AComponent;
  UpdateHandles;
  SurfaceSelectionChanged;
end;

function TFormDesigner.IsSelected(AComponent: TComponent): Boolean;
begin
  Result := FSelection.IndexOf(AComponent) >= 0;
end;

function TFormDesigner.SelectionCount: Integer;
begin
  Result := FSelection.Count;
end;

function TFormDesigner.SelectionAt(AIndex: Integer): TComponent;
begin
  Result := FSelection[AIndex];
end;

function TFormDesigner.SelectedInstances: TArray<TComponent>;
var
  I, Next: Integer;
begin
  SetLength(Result, FSelection.Count);
  Result[0] := FSelected;
  Next := 1;
  for I := 0 to FSelection.Count - 1 do
    if FSelection[I] <> FSelected then
    begin
      Result[Next] := FSelection[I];
      Inc(Next);
    end;
end;

function TFormDesigner.SelectedControls: TArray<TControl>;
var
  Item: TComponent;
begin
  Result := nil;
  for Item in FSelection do
    if (Item is TControl) and (Item <> FRoot) and not IsPlaceholder(Item) then
      Result := Result + [TControl(Item)];
end;

function TFormDesigner.PrimaryBounds: TRect;
var
  Items: TArray<TControl>;
begin
  if (FSelected is TControl) and not IsPlaceholder(FSelected) then
    Exit(TControl(FSelected).BoundsRect);
  Items := SelectedControls;
  if Length(Items) > 0 then
    Result := Items[0].BoundsRect
  else
    Result := TRect.Empty;
end;

procedure TFormDesigner.SelectParent;
begin
  if FSelected = FRoot then
    Exit;
  if FSelected is TControl then
    SelectComponent(TControl(FSelected).Parent)
  else if (FSelected <> nil) and (FSelected.GetParentComponent <> nil) then
    SelectComponent(FSelected.GetParentComponent)
  else
    SelectComponent(FRoot);
end;

{ geometry }

function TFormDesigner.SnapEnabled: Boolean;
begin
  Result := FSnapToGrid and (GetKeyState(VK_MENU) >= 0);
end;

function TFormDesigner.Snap(Value: Integer): Integer;
begin
  if SnapEnabled and (FGridSize > 1) then
    Result := Round(Value / FGridSize) * FGridSize
  else
    Result := Value;
end;

function TFormDesigner.ComputeDragRect(const CursorPos: TPoint): TRect;
var
  DX, DY: Integer;
begin
  DX := CursorPos.X - FDragAnchor.X;
  DY := CursorPos.Y - FDragAnchor.Y;
  Result := FDragOrigin;
  if FDragKind = dkMove then
  begin
    Result.Offset(DX, DY);
    Result := TRect.Create(Point(Snap(Result.Left), Snap(Result.Top)),
      FDragOrigin.Width, FDragOrigin.Height);
  end
  else
  begin
    if FResizeHandle in [hkTopLeft, hkLeft, hkBottomLeft] then
      Result.Left := Snap(Result.Left + DX);
    if FResizeHandle in [hkTopRight, hkRight, hkBottomRight] then
      Result.Right := Snap(Result.Right + DX);
    if FResizeHandle in [hkTopLeft, hkTop, hkTopRight] then
      Result.Top := Snap(Result.Top + DY);
    if FResizeHandle in [hkBottomLeft, hkBottom, hkBottomRight] then
      Result.Bottom := Snap(Result.Bottom + DY);
    if Result.Right <= Result.Left then
      Result.Right := Result.Left + 1;
    if Result.Bottom <= Result.Top then
      Result.Bottom := Result.Top + 1;
  end;
end;

procedure TFormDesigner.ShowDragFrame;
begin
  if FDragParent <> nil then
    FDragFrame.ShowRect(FDragParent, FDragRect);
end;

procedure TFormDesigner.CommitDrag;
var
  DX, DY: Integer;
  Item: TComponent;
  Control: TControl;
  Position: TPoint;
begin
  if FSelected = FRoot then
    Exit;
  if FDragRect = FDragOrigin then
    Exit;
  if FDragKind = dkResize then
  begin
    PushUndo(uoResize);
    ApplyBounds(TControl(FSelected), FDragRect.Left, FDragRect.Top,
      FDragRect.Width, FDragRect.Height);
    Exit;
  end;
  PushUndo(uoMove);
  DX := FDragRect.Left - FDragOrigin.Left;
  DY := FDragRect.Top - FDragOrigin.Top;
  for Item in FSelection do
  begin
    if (Item = FRoot) or IsPlaceholder(Item) then
      Continue;
    if Item is TControl then
    begin
      Control := TControl(Item);
      ApplyBounds(Control, Control.Left + DX, Control.Top + DY, Control.Width,
        Control.Height);
    end
    else if IsNonVisual(Item) then
    begin
      Position := TilePosition(Item);
      MoveTile(Item, Position.X + DX, Position.Y + DY);
    end;
  end;
  UpdateHandles;
end;

procedure TFormDesigner.CancelDrag;
begin
  if FDragKind = dkNone then
    Exit;
  // A resize runs on the handle window's own mouse capture, released on
  // button-up; only the move capture is released here.
  if FDragKind <> dkResize then
    ReleaseCapture;
  FDragFrame.Hide;
  FDragKind := dkNone;
  GestureEnded;
end;

procedure TFormDesigner.SyncFrameHost;
begin
  if (FForm = nil) or (TComponent(FForm) = FRoot) or not (FRoot is TControl) then
    Exit;
  SizeFrameHost(FForm, TControl(FRoot));
  // The tile layer positions tiles in the host's client space, which the
  // frame just moved within.
  UpdateTiles;
end;

procedure TFormDesigner.ApplyBounds(AControl: TControl;
  ALeft, ATop, AWidth, AHeight: Integer);
begin
  if AWidth < 1 then
    AWidth := 1;
  if AHeight < 1 then
    AHeight := 1;
  AControl.SetBounds(ALeft, ATop, AWidth, AHeight);
  if TComponent(AControl) = FRoot then
    SyncFrameHost;
  FHandles.Update;
  Modified;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

procedure TFormDesigner.MoveTile(AComponent: TComponent; X, Y: Integer);
begin
  SetTilePosition(AComponent, X, Y);
  InvalidateSurface;
  Modified;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

{ group commands }

function HoldsPlaceholder(AParent: TWinControl; AKind: TControlClass): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AParent = nil then
    Exit;
  for I := 0 to AParent.ControlCount - 1 do
    if (AParent.Controls[I] is AKind) and IsPlaceholder(AParent.Controls[I]) then
      Exit(True);
end;

procedure SpaceEqually(const AItems: TArray<TControl>; AHorizontal: Boolean);
var
  Sorted: TArray<TControl>;
  Extent, Gap, Position, I: Integer;
begin
  if Length(AItems) < 3 then
    Exit;
  Sorted := Copy(AItems);
  if AHorizontal then
    TArray.Sort<TControl>(Sorted, TComparer<TControl>.Construct(
      function(const A, B: TControl): Integer
      begin
        Result := A.Left - B.Left;
      end))
  else
    TArray.Sort<TControl>(Sorted, TComparer<TControl>.Construct(
      function(const A, B: TControl): Integer
      begin
        Result := A.Top - B.Top;
      end));
  Extent := 0;
  for I := 1 to High(Sorted) - 1 do
    if AHorizontal then
      Inc(Extent, Sorted[I].Width)
    else
      Inc(Extent, Sorted[I].Height);
  if AHorizontal then
    Gap := (Sorted[High(Sorted)].Left - (Sorted[0].Left + Sorted[0].Width) -
      Extent) div (Length(Sorted) - 1)
  else
    Gap := (Sorted[High(Sorted)].Top - (Sorted[0].Top + Sorted[0].Height) -
      Extent) div (Length(Sorted) - 1);
  if AHorizontal then
    Position := Sorted[0].Left + Sorted[0].Width + Gap
  else
    Position := Sorted[0].Top + Sorted[0].Height + Gap;
  for I := 1 to High(Sorted) - 1 do
  begin
    if AHorizontal then
    begin
      Sorted[I].Left := Position;
      Inc(Position, Sorted[I].Width + Gap);
    end
    else
    begin
      Sorted[I].Top := Position;
      Inc(Position, Sorted[I].Height + Gap);
    end;
  end;
end;

// Counts only siblings belonging to the document: handles and outlines are
// parented beside them and are in no order a form file holds.
function TFormDesigner.SiblingIndex(AControl: TControl): Integer;
var
  Parent: TWinControl;
  Sibling: TControl;
  I, Seen: Integer;
begin
  Result := -1;
  Parent := AControl.Parent;
  if Parent = nil then
    Exit;
  Seen := 0;
  for I := 0 to Parent.ControlCount - 1 do
  begin
    Sibling := Parent.Controls[I];
    if Sibling = AControl then
      Exit(Seen);
    if BelongsToDocument(Sibling) then
      Inc(Seen);
  end;
end;

function TFormDesigner.CanRestackSelection: Boolean;
var
  Item: TControl;
begin
  Result := False;
  if FGuarded then
    Exit;
  for Item in SelectedControls do
    if Item.Parent <> nil then
      Exit(True);
end;

procedure TFormDesigner.RestackSelection(AStep: TZOrderStep);
var
  Moved: TArray<TControl>;
  Item: TControl;
  Before: TArray<Integer>;
  I: Integer;
  Kept, Changed: Boolean;
begin
  if FGuarded then
    Exit;
  Moved := nil;
  Kept := False;
  for Item in SelectedControls do
    if Item.Parent <> nil then
    begin
      Moved := Moved + [Item];
      Kept := Kept or HoldsPlaceholder(Item.Parent, TControl);
    end;
  if Length(Moved) = 0 then
    Exit;
  TArray.Sort<TControl>(Moved, TComparer<TControl>.Construct(
    function(const A, B: TControl): Integer
    begin
      Result := SiblingIndex(A) - SiblingIndex(B);
    end));
  SetLength(Before, Length(Moved));
  for I := 0 to High(Moved) do
    Before[I] := SiblingIndex(Moved[I]);
  PushUndo(uoZOrder);
  if AStep = zsToFront then
    for I := 0 to High(Moved) do
      Moved[I].BringToFront
  else
    for I := High(Moved) downto 0 do
      Moved[I].SendToBack;
  // Called even when nothing moved: the chrome is parented beside the
  // controls, so a step that passed it has to put it back on top.
  UpdateHandles;
  InvalidateSurface;
  Changed := False;
  for I := 0 to High(Moved) do
    Changed := Changed or (SiblingIndex(Moved[I]) <> Before[I]);
  if not Changed then
  begin
    DropUndo;
    Exit;
  end;
  if Kept and (FLog <> nil) then
    FLog.Add(lsWarn, 'a component kept as found sits in the same container: ' +
      'its place in the file is preserved text the designer does not rewrite, ' +
      'so the moved controls cannot pass it');
  Modified;
  StructureChanged;
end;

procedure TFormDesigner.AlignSelection(AHorizontal: TAlignHorizontal;
  AVertical: TAlignVertical);
var
  Items: TArray<TControl>;
  Item: TControl;
  Reference, Area: TRect;
begin
  if ((AHorizontal = ahNone) and (AVertical = avNone)) or FGuarded then
    Exit;
  Items := SelectedControls;
  if Length(Items) = 0 then
    Exit;
  Reference := PrimaryBounds;
  PushUndo(uoMove);
  for Item in Items do
  begin
    Area := TRect.Empty;
    if Item.Parent <> nil then
      Area := Item.Parent.ClientRect;
    case AHorizontal of
      ahLeft: Item.Left := Reference.Left;
      ahCenters: Item.Left := Reference.Left + (Reference.Width - Item.Width) div 2;
      ahRight: Item.Left := Reference.Right - Item.Width;
      ahCenterInWindow: Item.Left := (Area.Width - Item.Width) div 2;
    end;
    case AVertical of
      avTop: Item.Top := Reference.Top;
      avMiddles: Item.Top := Reference.Top + (Reference.Height - Item.Height) div 2;
      avBottom: Item.Top := Reference.Bottom - Item.Height;
      avCenterInWindow: Item.Top := (Area.Height - Item.Height) div 2;
    end;
  end;
  if AHorizontal = ahSpaceEqually then
    SpaceEqually(Items, True);
  if AVertical = avSpaceEqually then
    SpaceEqually(Items, False);
  UpdateHandles;
  InvalidateSurface;
  Modified;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

procedure TFormDesigner.SizeSelection(AWidth, AHeight: TSizeMatch);
var
  Items: TArray<TControl>;
  Item: TControl;
  Reference: TRect;
begin
  if ((AWidth = smNone) and (AHeight = smNone)) or FGuarded then
    Exit;
  Items := SelectedControls;
  if Length(Items) = 0 then
    Exit;
  Reference := PrimaryBounds;
  PushUndo(uoResize);
  for Item in Items do
  begin
    if AWidth = smFromPrimary then
      Item.Width := Reference.Width;
    if AHeight = smFromPrimary then
      Item.Height := Reference.Height;
  end;
  UpdateHandles;
  InvalidateSurface;
  Modified;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

// Each TabOrder write shifts the entries after it, so assigning front to back
// reproduces AOrder exactly.
procedure TFormDesigner.ApplyTabOrder(const AOrder: TArray<TComponent>);
var
  I: Integer;
  Container: TWinControl;
begin
  if Length(AOrder) = 0 then
    Exit;
  Container := nil;
  if AOrder[0] is TControl then
    Container := TControl(AOrder[0]).Parent;
  if HoldsPlaceholder(Container, TWinControl) then
  begin
    if FLog <> nil then
      FLog.AddFmt(lsWarn, 'the tab order of %s was not changed: it contains ' +
        'a component kept as found, whose position is in preserved text the ' +
        'designer does not rewrite', [Container.Name]);
    Exit;
  end;
  PushUndo(uoProperty);
  for I := 0 to High(AOrder) do
    if AOrder[I] is TWinControl then
      TWinControl(AOrder[I]).TabOrder := I;
  Modified;
end;

procedure TFormDesigner.ApplyCreationOrder(const AOrder: TArray<TComponent>);
var
  I: Integer;
begin
  if Length(AOrder) = 0 then
    Exit;
  PushUndo(uoProperty);
  for I := 0 to High(AOrder) do
    AOrder[I].ComponentIndex := I;
  Modified;
  StructureChanged;
end;

procedure TFormDesigner.NoteFormSize(AWidth, AHeight: Integer);
var
  Size: TPoint;
begin
  // Only the client size is tracked: it is a stored property, while the
  // embedded form's screen position is presentation only.
  if not FTrackGeometry then
    Exit;
  Size := Point(AWidth, AHeight);
  if Size = FLastClientSize then
    Exit;
  FLastClientSize := Size;
  FSizeGestureChanged := True;
  Modified;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

// Windows' modal sizing loop resizes the form outside the designer's message
// flow, so the undo entry is taken up front and dropped when nothing changed.
procedure TFormDesigner.BeginSizeGesture;
begin
  FSizeGestureChanged := False;
  FSizeGestureRunning := True;
  PushUndo(uoRootResize);
end;

procedure TFormDesigner.EndSizeGesture;
begin
  FSizeGestureRunning := False;
  if not FSizeGestureChanged then
    DropUndo;
  GestureEnded;
end;

procedure TFormDesigner.NotifyEdited;
begin
  UpdateHandles;
  SyncFrameHost;
  if TComponent(FForm) = FRoot then
    FLastClientSize := Point(FForm.ClientWidth, FForm.ClientHeight);
  InvalidateSurface;
  Modified;
end;

procedure TFormDesigner.BeginEditing;
begin
  FEditing := True;
  if TComponent(FForm) = FRoot then
    FLastClientSize := Point(FForm.ClientWidth, FForm.ClientHeight);
  FTrackGeometry := True;
  UpdateHandles;
  QueueSettle;
end;

procedure TFormDesigner.GuardReadOnly;
begin
  FGuarded := True;
end;

procedure TFormDesigner.LiftGuard;
begin
  if not FGuarded then
    Exit;
  FGuarded := False;
  if FLog <> nil then
    FLog.Add(lsWarn, 'the read-only guard was lifted - saving with ' +
      'unresolved references is this user''s call from here on');
end;

{ save and close }

procedure TFormDesigner.WriteTo(const APath: string);
begin
  SinkChrome;
  SaveDesignedForm(FRoot, FEventMap, FLoadedState, FFrames, FPreserved,
    FAncestor.Root, APath);
end;

function TFormDesigner.Save: Boolean;
begin
  Result := False;
  if FGuarded then
  begin
    if FLog <> nil then
      FLog.Add(lsWarn, 'not saved: the document is read-only because ' +
        'references stayed unresolved. "Edit anyway" lifts the guard.');
    Exit;
  end;
  try
    WriteTo(FFileName);
    MarkDirty(False);
    Result := True;
    if FLog <> nil then
      FLog.AddFmt(lsInfo, 'saved %s', [FFileName]);
    // Raised last and only after a successful write; listeners read the file.
    if Assigned(FOnSaved) then
      FOnSaved(Self);
  except
    on E: Exception do
    begin
      if FLog <> nil then
        FLog.AddFmt(lsError, 'saving %s failed: %s', [FFileName, E.Message]);
      MessageDlg(Format('Saving %s failed:'#13#10'%s: %s',
        [FFileName, E.ClassName, E.Message]), mtError, [mbOK], 0);
    end;
  end;
end;

function TFormDesigner.ConfirmClose: Boolean;
begin
  Result := True;
  if not FDirty then
    Exit;
  case MessageDlg(Format('Save changes to %s?', [ExtractFileName(FFileName)]),
    mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
    mrYes: Result := Save;
    mrNo: Result := True;
  else
    Result := False;
  end;
end;

end.
