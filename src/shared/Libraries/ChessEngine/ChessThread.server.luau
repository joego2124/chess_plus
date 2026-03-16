--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EngineTypes = require(ReplicatedStorage.Modules.Libraries.ChessEngine.EngineTypes)
local Minimax = require(ReplicatedStorage.Modules.Libraries.ChessEngine.Minimax)
local ChessUtils = require(ReplicatedStorage.Modules.Libraries.ChessUtils)
local ChessTypes = require(ReplicatedStorage.Modules.Types.ChessTypes)

local Actor = script.Parent :: Actor
Actor:SetAttribute(EngineTypes.ActorAttributes.Busy, false)
Actor:SetAttribute(EngineTypes.ActorAttributes.Evaluation, 0)

Actor:BindToMessageParallel(
	EngineTypes.Topics.ExploreMove,
	function(
		boardState: ChessTypes.BoardState,
		turnColor: ChessTypes.PieceColor,
		piece: ChessTypes.Piece,
		targCoord: Vector2,
		searchDepth: number
	)
		task.desynchronize()
		debug.profilebegin(`{turnColor}{piece.Type}{targCoord}`)

		local newBoardState = ChessUtils.cloneBoard(boardState)
		ChessUtils.movePiece(newBoardState, newBoardState[piece.Coord.X][piece.Coord.Y], targCoord)

		local newEval =
			Minimax.miniMax(newBoardState, searchDepth, -math.huge, math.huge, turnColor)
		--NOTE: add slight offset so as to trigger AttributeChanged signal
		newEval = newEval == Actor:GetAttribute(EngineTypes.ActorAttributes.Evaluation)
				and newEval + 0.0001
			or newEval

		debug.profileend()
		task.synchronize()
		Actor:SetAttribute(EngineTypes.ActorAttributes.Evaluation, newEval)
		-- print(
		-- 	`[SNT] evaluating moving {piece.Color} {piece.Type} from {piece.Coord} to {targCoord} with eval {newEval}`
		-- )
	end
)
