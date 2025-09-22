--!strict

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientEffects = require(script.ClientEffects)
local CameraController = require(script.Parent.CameraController)
local ChessUtils = require(ReplicatedStorage.Modules.Libraries.ChessUtils)
local Spring = require(ReplicatedStorage.Modules.Libraries.Spring)
local ChessTypes = require(ReplicatedStorage.Modules.Types.ChessTypes)

local ChessController = {}

local Camera = workspace.CurrentCamera
local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()

local GameServiceRemote: RemoteEvent
local MenuObjects = Instance.new("Model", workspace)

-- Current client game vars
local Selectables: { [string]: ClientEffects.Selectable } = {}
local playerColor: ChessTypes.PieceColor = "White" -- Default, gets set when game starts
local BoardModel: Model
local DefaultSquare = ReplicatedStorage.Assets.Board.DefaultSquare
-- DefaultSquare.Size = Vector3.new(1, 0.25, 1)
local currentChessGame: ChessTypes.ChessGame

-- TODO: Temp testing states for promotion
local isPromoting = false
local PromotionContainer: Model

local MENU_CAM_POS = Vector3.new(0, 0, 0)
local function initMenuScreen()
	-- Set up camera
	CameraController.camFocus = MENU_CAM_POS + Vector3.zAxis * 50
	CameraController.camPos = MENU_CAM_POS

	-- Set up menu pieces
	local PawnSelectable =
		ClientEffects.createUISelectable(ReplicatedStorage.Assets.Pieces.Pawn:Clone())
	local PawnModel = PawnSelectable.Model
	local PawnDisplay = PawnSelectable.Display
	PawnModel.Parent = MenuObjects
	PawnModel:ScaleTo(0.5)
	PawnDisplay:SetAttribute("OrigSize", PawnDisplay.Size)
	ClientEffects.floatPiece(PawnModel, CFrame.new(CameraController.camFocus))
	Selectables[PawnSelectable.Model:GetAttribute("UID") :: string] = PawnSelectable

	-- Create billboard label
	local LabelGUI, textObject = ClientEffects.popupBillboardText(
		"play!",
		PawnDisplay,
		UDim2.fromScale(PawnDisplay.Size.Y * 4, PawnDisplay.Size.Y * 2),
		Vector3.zero,
		"Persistent",
		{
			Looping = true,
			AnimateStyle = "Float",
			AnimateStyleTime = 4,
			AnimateStyleAmplitude = 0.1,
			Font = Enum.Font.DenkOne,
			TextStrokeTransparency = 0,
			BorderSizePixel = 3,
			TextScale = 1,
			ContainerHorizontalAlignment = "Center",
		}
	)
	local CanvasGroup = LabelGUI:FindFirstChildOfClass("CanvasGroup") :: CanvasGroup

	-- Set up click detector
	-- TODO: refactor this out
	local origFrameSize = CanvasGroup.Size
	local Detector = Instance.new("ClickDetector", PawnModel)
	Detector.MaxActivationDistance = math.huge
	Detector.MouseClick:Connect(function() GameServiceRemote:FireServer("RequestGame") end)
	local incScale = 0.5
	local TWEEN_TIME = 0.25
	Detector.MouseHoverEnter:Connect(function()
		TweenService:Create(
			CanvasGroup,
			TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{
				Size = origFrameSize + UDim2.fromScale(incScale, incScale),
			}
		):Play()
		for _, Label in pairs(LabelGUI:GetDescendants()) do
			if not Label:IsA("TextLabel") or not Label.Name:find("Char") then continue end
			TweenService:Create(Label, TweenInfo.new(TWEEN_TIME), {
				TextColor3 = ChessTypes.menuColors.playAIColor,
			}):Play()
		end
		textObject:animateChars()
	end)
	Detector.MouseHoverLeave:Connect(function()
		TweenService:Create(
			CanvasGroup,
			TweenInfo.new(TWEEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{
				Size = origFrameSize,
			}
		):Play()
		for _, Label in pairs(LabelGUI:GetDescendants()) do
			if not Label:IsA("TextLabel") or not Label.Name:find("Char") then continue end
			TweenService:Create(Label, TweenInfo.new(TWEEN_TIME), {
				TextColor3 = Color3.fromRGB(255, 255, 255),
			}):Play()
		end
	end)
end

--[[
	Mouse enter / leave player piece
]]
local DraggedSelectable: ClientEffects.Selectable?
local draggedTargetCF: CFrame = CFrame.new()
local HoveredSelectable: ClientEffects.Selectable?
local mouseBoardCoord: Vector2

local function clearPieces()
	HoveredSelectable = nil
	DraggedSelectable = nil
	ChessUtils.iterateBoard(currentChessGame.state, function(piece)
		local Selectable = Selectables[piece.UID]
		if not Selectable then
			if piece.Type ~= "NA" then
				warn(`{piece.Color} {piece.Type} has no Selectable cached!`)
			end
			return
		end
		Selectable.Model:Destroy()
		Selectables[piece.UID] = nil
	end)
end

-- Helper function to place piece at mouse cf relative to board
local function getSelectedPieceMouseCF(PieceModel: Model)
	local camPos = Camera.CFrame.Position
	local hoverRootPos = BoardModel.WorldPivot + Vector3.new(0, DefaultSquare.Size.X * 3.5)
	local dist = math.abs(camPos.Y - hoverRootPos.Y)
	local camToMouseDir = (camPos - Mouse.Hit.Position).Unit
	local ang = math.acos(-Vector3.yAxis:Dot(camToMouseDir))

	local DisplayPart = PieceModel:FindFirstChild("Display") :: BasePart
	return CFrame.new(
		CFrame.lookAt(camPos, Mouse.Hit.Position) * CFrame.new(0, 0, dist * math.cos(ang)).Position
	) * CFrame.new(0, -DisplayPart.Size.Y / 2, 0)
end

local HOVER_FLOAT_TIME_S = 0.1
local function unhoverSelectable()
	if not HoveredSelectable then return end
	local uid = HoveredSelectable.Model:GetAttribute("UID") :: string
	local Selectable = Selectables[uid]
	ClientEffects.unselectSelectable(Selectable)
	ClientEffects.hideMoveHighlights()
	HoveredSelectable = nil
end

-- Piece dragging
local PIECE_ROT_LIMIT_RAD = math.pi / 3
local prevSelectedPiecePos = Vector3.zero
local rotSpring = Spring.new(Vector2.zero)
local posSpring = Spring.new(Vector3.zero)
rotSpring.Damper = 0.4
rotSpring.Speed = 20
posSpring.Damper = 1
posSpring.Speed = 30
local tweenedVel = Vector3.zero -- intermediary value required for lerp

RunService.Heartbeat:Connect(function(dt: number)
	-- TODO: temp test
	for _, Selectable in pairs(Selectables) do
		if (Selectable.sizeSpring.Target - Selectable.sizeSpring.Position).Magnitude < 0.01 then
			continue
		end
		Selectable.Display.Size = Selectable.sizeSpring.Position
	end

	if not DraggedSelectable then return end

	-- Promotion UI pieces gets set as DraggedSelectable, skip drag stuff
	if isPromoting then return end

	-- Update vel from mouse movement
	local offsetCF = CFrame.new(0, DraggedSelectable.Display.Size.Y / 2, 0)
	local vel = (draggedTargetCF.Position - prevSelectedPiecePos) / dt * 0.05
	tweenedVel = tweenedVel + (vel - tweenedVel) * (1 - math.exp(-rotSpring.Speed * 20 * dt))

	-- Update springs and apply CF
	rotSpring:SetTarget(Vector2.new(tweenedVel.X, tweenedVel.Z))
	posSpring:SetTarget(draggedTargetCF.Position)

	DraggedSelectable.Display.CFrame = CFrame.new(posSpring.Position)
		* offsetCF
		* CFrame.Angles(
			math.clamp(rotSpring.Position.Y, -PIECE_ROT_LIMIT_RAD, PIECE_ROT_LIMIT_RAD),
			0,
			-math.clamp(rotSpring.Position.X, -PIECE_ROT_LIMIT_RAD, PIECE_ROT_LIMIT_RAD)
		)
		* offsetCF:Inverse()

	-- Update prev pos
	prevSelectedPiecePos = draggedTargetCF.Position
end)

local function placePiece(targetCoord: Vector2, pieceUID: string): boolean
	local selectedPiece = ChessUtils.getPieceFromUID(pieceUID, currentChessGame.state)
	if
		not selectedPiece
		or not ChessUtils.isMoveValid(selectedPiece, targetCoord, currentChessGame.state)
	then
		return false
	end
	GameServiceRemote:FireServer("PlacePiece", targetCoord, pieceUID)
	return true
end

Mouse.Button1Down:Connect(function()
	if not currentChessGame then return end -- TODO: temp hack for menu

	-- TODO: temp hack for clicking promotion ui pieces
	if currentChessGame and playerColor ~= currentChessGame.turn or not HoveredSelectable then
		return
	end

	DraggedSelectable = HoveredSelectable
	draggedTargetCF = getSelectedPieceMouseCF(HoveredSelectable.Model)
	prevSelectedPiecePos = draggedTargetCF.Position
	posSpring.Position = prevSelectedPiecePos
	rotSpring.Position = Vector2.zero
end)

Mouse.Button1Up:Connect(function()
	if not currentChessGame then return end

	-- Promotion selection cleanup
	if isPromoting and DraggedSelectable then
		GameServiceRemote:FireServer("PromotePiece", DraggedSelectable.Model.Name)
		isPromoting = false
		ReplicatedStorage.Assets.Sounds.PitchUp:Play()
		local offsetDelay = HOVER_FLOAT_TIME_S / 4
		task.defer(function()
			for _, PieceModel in pairs(PromotionContainer:GetChildren()) do
				local Display = PieceModel:FindFirstChild("Display") :: BasePart
				TweenService
					:Create(Display, TweenInfo.new(HOVER_FLOAT_TIME_S), { Size = Vector3.zero })
					:Play()
				task.wait(offsetDelay)
			end
			local numPieces = #PromotionContainer:GetChildren()
			task.delay(
				(HOVER_FLOAT_TIME_S + offsetDelay) * numPieces,
				function() PromotionContainer:Destroy() end
			)
		end)
	end

	if not DraggedSelectable then return end

	-- TODO: temp hack for placing items, need to add hover debounce
	if DraggedSelectable.Type == "Item" then
		unhoverSelectable()
		DraggedSelectable.Hitbox.CFrame = draggedTargetCF
		DraggedSelectable.Display.CFrame = draggedTargetCF
		DraggedSelectable = nil
		return
	end

	-- Try to place piece
	if ChessUtils.isCoordValid(mouseBoardCoord, currentChessGame.state) then
		local isCapture = not ChessUtils.isCoordEmpty(mouseBoardCoord, currentChessGame.state)
		if placePiece(mouseBoardCoord, DraggedSelectable.Model:GetAttribute("UID") :: string) then
			ClientEffects.hideMoveHighlights()
			ReplicatedStorage.Assets.Sounds[isCapture and "Take" or "Move"]:Play()
			return
		end
	end

	-- Invalid placement, replace part to start
	DraggedSelectable.Display.CFrame = DraggedSelectable.Model.WorldPivot
	unhoverSelectable()
	DraggedSelectable = nil
	HoveredSelectable = nil
	ReplicatedStorage.Assets.Sounds.Hover:Play()
end)

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include

UserInputService.InputChanged:Connect(function(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end

	-- Handle promotion selection
	if isPromoting then
		if
			Mouse.Target
			and Mouse.Target.Parent
			and Mouse.Target:IsDescendantOf(PromotionContainer)
		then
			local PieceModel = Mouse.Target.Parent
			local pieceUID: string? = PieceModel:GetAttribute("UID")
			if not pieceUID then return end
			local PieceSelectable = Selectables[pieceUID]
			if HoveredSelectable == PieceSelectable then return end
			unhoverSelectable()
			HoveredSelectable = PieceSelectable
			DraggedSelectable = PieceSelectable -- TODO: still temp fix for being able to click
			ClientEffects.selectSelectable(Selectables[pieceUID], true)
			ReplicatedStorage.Assets.Sounds.Bubble:Play()
			return
		end

		-- Unselect prev selected promotion piece
		unhoverSelectable()
		DraggedSelectable = nil
		return
	end

	-- Update which board square coord is mouse in
	local mouseHitPos = Mouse.Hit.Position
	local camPos = Camera.CFrame.Position
	local camToMouseDir = (mouseHitPos - camPos).Unit
	local ray = Workspace:Raycast(camPos, camToMouseDir * 9999, params)
	if ray and ray.Instance and ray.Instance.Parent then
		mouseBoardCoord =
			Vector2.new(tonumber(ray.Instance.Parent.Name), tonumber(ray.Instance.Name))
	else
		mouseBoardCoord = Vector2.zero
	end

	-- State for when piece is already being dragged, skip piece hover checks
	if DraggedSelectable and Mouse.Hit then
		draggedTargetCF = getSelectedPieceMouseCF(DraggedSelectable.Model)
		ClientEffects.updateMoveHighlights(mouseBoardCoord)
		return
	end

	-- Check mouse hit is valid
	if not Mouse.Target then
		unhoverSelectable()
		return
	end

	-- Check if mouse is hovering over a piece
	local PieceModel = Mouse.Target.Parent
	local pieceUID = PieceModel:GetAttribute("UID") :: string?
	if not PieceModel or not pieceUID then
		unhoverSelectable()
		return
	end
	local PieceSelectable = Selectables[pieceUID]

	-- Do nothing if hovering over same piece
	if not PieceSelectable or HoveredSelectable == PieceSelectable then return end

	-- Ignore if hovering over enemy's piece
	local hoveringPiece: ChessTypes.Piece?
	if currentChessGame then -- if this is a game piece
		hoveringPiece = ChessUtils.getPieceFromUID(pieceUID, currentChessGame.state)
		if hoveringPiece and ((hoveringPiece.Color ~= playerColor) and true) then
			unhoverSelectable()
			return
		end
	end

	-- Unhover currently hovered piece if applicable
	unhoverSelectable()

	-- Apply hover effect to newly hovered piece
	local isPlayerTurn = (hoveringPiece and currentChessGame) -- TODO: fix logic
			and (currentChessGame.turn == playerColor)
		or true
	ClientEffects.selectSelectable(PieceSelectable, isPlayerTurn)
	HoveredSelectable = PieceSelectable

	-- Highlight moves
	if hoveringPiece then
		ClientEffects.highlightMoves(
			hoveringPiece :: ChessTypes.Piece,
			currentChessGame.state,
			BoardModel,
			isPlayerTurn
		)
	end

	-- Play sound
	ReplicatedStorage.Assets.Sounds.Hover:Play()
end)

local function setupGame(chessGame: ChessTypes.ChessGame)
	-- Hide menu objects
	MenuObjects.Parent = Lighting

	-- Create board
	local Board = ClientEffects.buildBoard()
	BoardModel = Board
	for _, RankModel in pairs(BoardModel:GetChildren()) do
		if not RankModel:IsA("Model") then continue end
		for _, Square in pairs(RankModel:GetChildren()) do
			params:AddToFilter(Square)
		end
	end

	-- Set board CFrame and camera focus
	local ReferenceGUI = ReplicatedStorage.Assets.UI.ReferenceGUI
	ReferenceGUI.Parent = Player.PlayerGui
	local projectedCF =
		CameraController.fitPartToFrame(Board.PrimaryPart :: Part, ReferenceGUI.BoardArea)
	local dist = (Camera.CFrame.Position - projectedCF.Position).Magnitude
	local boardCF = CFrame.new(MENU_CAM_POS)
		* CFrame.new(
			0, -- -dist * math.sin(ClientEffects.ANG_FROM_VERT_RAD),
			-dist * math.cos(ClientEffects.ANG_FROM_VERT_RAD),
			dist * math.sin(ClientEffects.ANG_FROM_VERT_RAD)
		)
	Board:PivotTo(boardCF)

	CameraController.camFocus = boardCF.Position

	-- Populate initial board pieces from given state
	updateGame(chessGame)

	-- Set player color
	playerColor = (chessGame.WhitePlayer == Player and "White" or "Black") :: ChessTypes.PieceColor

	-- TODO: temp setup for item testing
	-- local IceSelectable =
	-- 	ClientEffects.createItemSelectable(ReplicatedStorage.Assets.Items.Ice:Clone())
	-- Selectables[IceSelectable.UID] = IceSelectable
	-- IceSelectable.Model.Parent = workspace
	-- IceSelectable.Model:PivotTo(BoardModel.WorldPivot * CFrame.new(0, 1, 0))

	-- local AirStrikeSelectable =
	-- 	ClientEffects.createItemSelectable(ReplicatedStorage.Assets.Items.AirStrike:Clone())
	-- Selectables[AirStrikeSelectable.UID] = AirStrikeSelectable
	-- AirStrikeSelectable.Model.Parent = workspace
	-- AirStrikeSelectable.Model:PivotTo(BoardModel.WorldPivot * CFrame.new(3, 1, -3))
end

function updateGame(updateChessGame: ChessTypes.ChessGame)
	if
		currentChessGame
		and currentChessGame.promotingPiece
		and not updateChessGame.promotingPiece
	then
		local promotingPiece = currentChessGame.promotingPiece
		local pawnHeight = Selectables[promotingPiece.UID].Display.Size.Y
		local PromotingSquare = ChessUtils.getBoardSquareFromCoord(promotingPiece.Coord, BoardModel)
		local PieceSelectable = Selectables[promotingPiece.UID]
		ClientEffects.popupBillboardText(
			"promoted!",
			PromotingSquare,
			UDim2.fromScale(pawnHeight * 4, pawnHeight * 2),
			Vector3.new(0, PieceSelectable.Display.Size.Y, 0),
			"Temporary"
		)
	end
	if currentChessGame then clearPieces() end
	currentChessGame = updateChessGame
	local newSelectables = ClientEffects.populatePieces(BoardModel, currentChessGame.state)
	for UID, Selectable in pairs(newSelectables) do --TODO: temp hacky way of updating
		Selectables[UID] = Selectable
	end
end

function ChessController.init(RuntimeFolder: Folder, RemotesFolder: Folder)
	GameServiceRemote = RemotesFolder:FindFirstChild("GameServiceRemote", true) :: RemoteEvent

	local function handlePromotion(targetCoord: Vector2, pieceUID: string)
		PromotionContainer = ClientEffects.promptPromotion(
			ChessUtils.getPieceFromUID(pieceUID, currentChessGame.state) :: ChessTypes.Piece,
			targetCoord,
			Selectables
		)
		isPromoting = true
	end

	GameServiceRemote.OnClientEvent:Connect(function(eventName: string, ...)
		if eventName == "StartGame" then
			setupGame(...)
		elseif eventName == "UpdateGame" then
			updateGame(...)
		elseif eventName == "PromptPromotion" then
			handlePromotion(...)
		end
	end)
end

function ChessController.start()
	-- Freeze character
	local Char = Player.Character or Player.CharacterAdded:Wait()
	local RootPart = Char:WaitForChild("HumanoidRootPart")
	RootPart.Anchored = true

	-- Init menu
	initMenuScreen()

	CameraController.changeState("Menu")
end

return ChessController
