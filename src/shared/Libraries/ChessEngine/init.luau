--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local EngineTypes = require(script.EngineTypes)
local ChessTypes = require(ReplicatedStorage.Modules.Types.ChessTypes)
local ChessUtils = require(script.Parent.ChessUtils)

local ChessEngine = {}

-- Parallel luau stuff

local NUM_ACTORS = 32
local ActorsFolder = Instance.new("Folder", ServerScriptService)
local Actors: { Actor } = {}
ActorsFolder.Name = "Actors"

for i = 1, NUM_ACTORS do
	local Actor = Instance.new("Actor", ActorsFolder)
	local newScript = script.ChessThread:Clone()
	newScript.Parent = Actor
	newScript.Enabled = true
	table.insert(Actors, Actor)
end

function ChessEngine.calculateMove(
	boardState: ChessTypes.BoardState,
	turnColor: ChessTypes.PieceColor,
	searchDepth: number
): (ChessTypes.Piece, Vector2)
	local pieceToMove: ChessTypes.Piece
	local bestCoord: Vector2
	local bestEval = turnColor == "White" and -math.huge or math.huge

	local pendingMoves = 0

	local function findIdleActor(): Actor
		local Actor: Actor
		local t = tick()
		repeat
			for i, v in ipairs(Actors) do
				if v:GetAttribute(EngineTypes.ActorAttributes.Busy) ~= false then continue end
				Actor = v
				break
			end
			if (tick() - t) > (1 / 30) then
				print(`no avail actors, frame time reached`)
				wait()
				t = tick()
			end
		until Actor
		return Actor
	end

	print(`----- CALCULATING MOVE -----`)
	local pending = {}
	local function evalMove(piece: ChessTypes.Piece, targCoord: Vector2)
		local Actor = findIdleActor()
		local conn: RBXScriptConnection
		conn = Actor:GetAttributeChangedSignal(EngineTypes.ActorAttributes.Evaluation)
			:Connect(function()
				local newEval = Actor:GetAttribute(EngineTypes.ActorAttributes.Evaluation) :: number
				if
					(turnColor == "White" and newEval > bestEval)
					or (turnColor == "Black" and newEval < bestEval)
					or ((newEval == bestEval) and (math.random() > 0.5))
				then
					bestEval = newEval
					pieceToMove = piece
					bestCoord = targCoord
				end
				pending[`{piece.Color} {piece.Type} from {piece.Coord} to {targCoord}`] = nil
				print(
					`[ACK] evaluating moving {piece.Color} {piece.Type} from {piece.Coord} to {targCoord} with eval {newEval}`
				)
				pendingMoves -= 1
				Actor:SetAttribute(EngineTypes.ActorAttributes.Busy, false)
				conn:Disconnect()
			end)
		Actor:SetAttribute(EngineTypes.ActorAttributes.Busy, true)
		Actor:SendMessage(
			EngineTypes.Topics.ExploreMove,
			boardState,
			turnColor,
			piece,
			targCoord,
			searchDepth
		)
	end

	-- Iterate through all potential pieces that can be moved
	ChessUtils.iterateBoard(boardState, function(piece: ChessTypes.Piece)
		-- Skip empty coords or non target color pieces
		if ChessUtils.isPieceEmpty(piece) or piece.Color ~= turnColor then return end

		-- Iterate through current piece's available moves and evaluate state
		for i, availCoord in pairs(ChessUtils.getValidMoves(piece, boardState)) do
			pendingMoves += 1
			pending[`{piece.Color} {piece.Type} from {piece.Coord} to {availCoord}`] = true
			evalMove(piece, availCoord)
		end
	end)

	-- Yield until all moves evaluated
	while pendingMoves > 0 do
		print(pending)
		wait()
	end

	return pieceToMove, bestCoord
end

return ChessEngine
