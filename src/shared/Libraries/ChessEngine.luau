--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChessTypes = require(ReplicatedStorage.Modules.Types.ChessTypes)
local ChessUtils = require(script.Parent.ChessUtils)

local ChessEngine = {}

local pieceValues: { [ChessTypes.PieceType]: number } = {
	Pawn = 1,
	Knight = 3,
	Bishop = 3.25,
	Rook = 5,
	Queen = 9,
	King = 1,
}

function ChessEngine.evaluateBoardState(boardState: ChessTypes.BoardState): number
	local stateEval = 0
	ChessUtils.iterateBoard(boardState, function(piece: ChessTypes.Piece)
		if ChessUtils.isPieceEmpty(piece) then return end
		local availableMoves = ChessUtils.getValidMoves(piece, boardState)
		local colorSign = piece.Color == "Black" and -1 or 1
		stateEval += colorSign * pieceValues[piece.Type] + #availableMoves
	end)
	return stateEval
end

local pruneCounter = 0
local function miniMax(
	boardState: ChessTypes.BoardState,
	searchDepth: number,
	alpha: number,
	beta: number,
	maximizingColor: ChessTypes.PieceColor
): number
	if searchDepth == 0 then return ChessEngine.evaluateBoardState(boardState) end

	local bestEval = maximizingColor == "White" and -math.huge or math.huge

	-- Iterate all current pieces
	ChessUtils.iterateBoard(boardState, function(piece: ChessTypes.Piece)
		-- Skip empty coords or opponent's pieces
		if ChessUtils.isPieceEmpty(piece) or piece.Color ~= maximizingColor then return end

		-- Iterate through current piece's available moves and evaluate state
		for i, availCoord in pairs(ChessUtils.getValidMoves(piece, boardState)) do
			local newBoardState = ChessUtils.cloneBoard(boardState)
			ChessUtils.movePiece(newBoardState, piece, availCoord)

			-- Recursively call minimax
			local newEval = miniMax(
				newBoardState,
				searchDepth - 1,
				alpha,
				beta,
				(maximizingColor == "White" and "Black" or "White") :: ChessTypes.PieceColor
			)

			-- Update best evaluation if applicable
			if
				(maximizingColor == "White" and newEval > bestEval)
				or (maximizingColor == "Black" and newEval < bestEval)
			then
				bestEval = newEval
				if maximizingColor == "White" then
					alpha = math.max(alpha, bestEval)
				elseif maximizingColor == "Black" then
					beta = math.max(beta, bestEval)
				end
				if beta <= alpha then
					pruneCounter += 1
					break
				end
			end
		end
	end)

	return bestEval
end

function ChessEngine.calculateMove(
	boardState: ChessTypes.BoardState,
	turnColor: ChessTypes.PieceColor,
	searchDepth: number
): (ChessTypes.Piece, Vector2)
	local pieceToMove: ChessTypes.Piece
	local targCoord: Vector2
	local bestEval = turnColor == "White" and -math.huge or math.huge
	pruneCounter = 0

	-- Iterate through all potential pieces that can be moved
	ChessUtils.iterateBoard(boardState, function(piece: ChessTypes.Piece)
		-- Skip empty coords or non target color pieces
		if ChessUtils.isPieceEmpty(piece) or piece.Color ~= turnColor then return end
		-- Iterate through current piece's available moves and evaluate state
		for i, availCoord in pairs(ChessUtils.getValidMoves(piece, boardState)) do
			local newBoardState = ChessUtils.cloneBoard(boardState)
			ChessUtils.movePiece(
				newBoardState,
				newBoardState[piece.Coord.X][piece.Coord.Y],
				availCoord
			)

			local newEval = miniMax(newBoardState, searchDepth, -math.huge, math.huge, turnColor)
			if
				(turnColor == "White" and newEval > bestEval)
				or (turnColor == "Black" and newEval < bestEval)
				or ((newEval == bestEval) and (math.random() > 0.5))
			then
				bestEval = newEval
				pieceToMove = piece
				targCoord = availCoord
			end
		end
	end)

	print(`Times pruned: {pruneCounter}`)
	return pieceToMove, targCoord
end

return ChessEngine
