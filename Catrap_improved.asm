; ====================================================================
; PROJECT: Catrap (Game Boy Port)
; RESTRICTIONS: NO DMA, NO INTERRUPTS, NO RST INSTRUCTIONS
; TEAM NUMBERS: XIAOKUN WANG 999025521, ENHAO HU 999025208
; ====================================================================

INCLUDE "hardware.inc"

; ====================================================================
; CONSTANTS
; ====================================================================

; Tile IDs — must match level data encoding and GameTiles order
DEF TILE_NOTHING    EQU $00
DEF TILE_STAIRS     EQU $01
DEF TILE_MONSTER    EQU $02
DEF TILE_ROCK       EQU $03
DEF TILE_SAND       EQU $04
DEF TILE_WALL       EQU $05
DEF TILE_GHOST      EQU $06
DEF TILE_PLAYER     EQU $07

DEF MAP_COLS        EQU 12
DEF MAP_ROWS        EQU 12
DEF MAP_SIZE        EQU 144
DEF ROWS_PER_FRAME  EQU 1    ; rows copied per VBlank

; Top-left corner of the 12x12 play area on the 32x32 background tilemap
DEF MAP_DISPLAY_COL EQU 4
DEF MAP_DISPLAY_ROW EQU 3

; Tilemap row/column positions for UI strings
DEF TITLE_STR_ROW   EQU 4
DEF TITLE_STR_COL   EQU 5
DEF PRESS_KEY_ROW   EQU 10
DEF PRESS_KEY_COL   EQU 3
DEF ENDING_STR_ROW  EQU 5
DEF ENDING_STR_COL  EQU 3
DEF ENDING_KEY_ROW  EQU 7
DEF ENDING_KEY_COL  EQU 3

DEF LEVEL_COUNT     EQU 10

; Button bitmasks (active-high, as returned by readKeys)
DEF PADB_A      EQU %00000001
DEF PADB_B      EQU %00000010
DEF PADB_SELECT EQU %00000100
DEF PADB_START  EQU %00001000
DEF PADB_RIGHT  EQU %00010000
DEF PADB_LEFT   EQU %00100000
DEF PADB_UP     EQU %01000000
DEF PADB_DOWN   EQU %10000000

; Character map: space -> tile 0, letters A-Z -> tiles 18-43
CHARMAP " ", 0
CHARMAP "A", 18
CHARMAP "B", 19
CHARMAP "C", 20
CHARMAP "D", 21
CHARMAP "E", 22
CHARMAP "F", 23
CHARMAP "G", 24
CHARMAP "H", 25
CHARMAP "I", 26
CHARMAP "J", 27
CHARMAP "K", 28
CHARMAP "L", 29
CHARMAP "M", 30
CHARMAP "N", 31
CHARMAP "O", 32
CHARMAP "P", 33
CHARMAP "Q", 34
CHARMAP "R", 35
CHARMAP "S", 36
CHARMAP "T", 37
CHARMAP "U", 38
CHARMAP "V", 39
CHARMAP "W", 40
CHARMAP "X", 41
CHARMAP "Y", 42
CHARMAP "Z", 43

; ====================================================================
; WRAM VARIABLES
; ====================================================================
SECTION "Variables", WRAM0

wCurrentLevel:  db
wMapBuffer:     ds MAP_SIZE
wPlayerX:       db
wPlayerY:       db
wMonsterCount:  db
wTargetX:       db
wTargetY:       db
previous:       db          ; readKeys internal: previous frame raw state
current:        db          ; readKeys output: rising-edge result
; wMapDirty: set to 1 by UpdateOneTile whenever wMapBuffer changes.
wMapDirty:      db
; wRedrawRow: next row to redraw; >= MAP_ROWS means idle.
wRedrawRow:     db
wFallingTile:   db


; ====================================================================
; ROM HEADER
; ====================================================================
SECTION "Header", ROM0[$100]
  jp EntryPoint
  ds $150 - @, 0

; ---------------------------------------------------------------------------
; EntryPoint: one-time initialization at power-on.
; ---------------------------------------------------------------------------
EntryPoint:
  call SafeTurnOffLCD

  ld a, %11111100
  ld [rBGP], a
  ld [rOBP0], a

  call CopyTilesToVRAM

  xor a
  ld [wCurrentLevel], a

  jp TitleScreen

; ---------------------------------------------------------------------------
; TitleScreen: draws title and waits for a key press, then starts level 0.
; ---------------------------------------------------------------------------
TitleScreen:
  call SafeTurnOffLCD
  call ResetBG
  call ResetOAM

  ld hl, TILEMAP0 + TITLE_STR_COL + (TITLE_STR_ROW * 32)
  ld de, TitleStr
  ld b, TitleStr.end - TitleStr
  call DrawString

  ld hl, TILEMAP0 + PRESS_KEY_COL + (PRESS_KEY_ROW * 32)
  ld de, PressStr
  ld b, PressStr.end - PressStr
  call DrawString

  xor a
  ld [wCurrentLevel], a

  ld a, LCDC_ON | LCDC_BG_ON | LCDC_BLOCK01
  ld [rLCDC], a

  call WaitKey
  jp StartLevel

; ---------------------------------------------------------------------------
; StartLevel: loads wCurrentLevel; shows ending screen if all levels cleared.
; ---------------------------------------------------------------------------
StartLevel:
  ld a, [wCurrentLevel]
  cp LEVEL_COUNT
  jp z, EndingScreen

  call SafeTurnOffLCD
  call ResetBG
  call ResetOAM

  call LoadLevel
  call DrawMapToBackground    ; initial full draw while PPU is off

  xor a
  ld [wMapDirty], a           ; map was just drawn; nothing pending

  ld a, MAP_ROWS
  ld [wRedrawRow], a          ; >= MAP_ROWS means idle

  ld a, LCDC_ON | LCDC_OBJ_ON | LCDC_BG_ON | LCDC_BLOCK01
  ld [rLCDC], a

; ---------------------------------------------------------------------------
; MainLoop: input -> logic -> VBlank -> VRAM/OAM update -> repeat.
;
; VRAM and OAM are only written inside VBlankUpdate (called after WaitVBlank):
;   - DrawMapRows: flushes pending map rows to VRAM (triggered by wMapDirty).
;   - UpdateOAM: writes player sprite directly to hardware OAM.
; ---------------------------------------------------------------------------
MainLoop:
  call readKeys
  call UpdateGameState        ; outside VBlank: logic only

  call WaitVBlank
  call VBlankUpdate           ; inside VBlank: all VRAM and OAM writes
  jp MainLoop

; ---------------------------------------------------------------------------
; VBlankUpdate: called once per VBlank to flush map changes and update OAM.
; All VRAM and OAM writes for the frame happen here.
; ---------------------------------------------------------------------------
VBlankUpdate:
  ; A map change schedules a fresh redraw starting from the top row.
  ld a, [wMapDirty]
  and a
  jr z, .checkRedraw
  xor a
  ld [wMapDirty], a
  ld [wRedrawRow], a          ; (re)start redraw at row 0

.checkRedraw:
  ld a, [wRedrawRow]
  cp MAP_ROWS
  jr nc, .skipDraw            ; >= MAP_ROWS: nothing pending
  ld b, a                     ; B = start row for this frame
  ld c, ROWS_PER_FRAME
  call DrawMapRows
  ld a, [wRedrawRow]
  add ROWS_PER_FRAME
  ld [wRedrawRow], a

.skipDraw:
  call UpdateOAM              ; write player sprite to hardware OAM
  ret

; ---------------------------------------------------------------------------
; EndingScreen: congratulations message, then back to title on any key.
; ---------------------------------------------------------------------------
EndingScreen:
  call SafeTurnOffLCD
  call ResetBG
  call ResetOAM

  ld hl, TILEMAP0 + ENDING_STR_COL + (ENDING_STR_ROW * 32)
  ld de, EndingStr
  ld b, EndingStr.end - EndingStr
  call DrawString

  ld hl, TILEMAP0 + ENDING_KEY_COL + (ENDING_KEY_ROW * 32)
  ld de, PressStr
  ld b, PressStr.end - PressStr
  call DrawString

  ld a, LCDC_ON | LCDC_BG_ON | LCDC_BLOCK01
  ld [rLCDC], a

  call WaitKey
  jp TitleScreen

; ====================================================================
; SECTION: FUNCTIONS
; ====================================================================
SECTION "Functions", ROM0

; ---------------------------------------------------------------------------
; SafeTurnOffLCD: waits for VBlank then disables the PPU.
; ---------------------------------------------------------------------------
SafeTurnOffLCD:
  ld a, [rLCDC]
  and LCDC_ON
  ret z
.wait:
  ld a, [rLY]
  cp 144
  jr nz, .wait
  xor a
  ld [rLCDC], a
  ret

; ---------------------------------------------------------------------------
; ResetOAM: zeroes all 160 bytes of hardware OAM (Y=0 hides all sprites).
; Called only while the PPU is off (e.g. during StartLevel / TitleScreen).
; ---------------------------------------------------------------------------
ResetOAM:
  ld hl, STARTOF(OAM)
  ld b, 160
  xor a
.loop:
  ld [hl+], a
  dec b
  jr nz, .loop
  ret

; ---------------------------------------------------------------------------
; WaitKey: polls readKeys until at least one button has a rising edge.
; ---------------------------------------------------------------------------
WaitKey:
.loop:
  call readKeys
  ld a, [current]
  and a
  jr z, .loop
  ret

; ---------------------------------------------------------------------------
; WaitVBlank: busy-loops until rLY reaches 144 (start of VBlank).
; ---------------------------------------------------------------------------
WaitVBlank:
  ld a, [rLY]
  cp 144
  jr nz, WaitVBlank
  ret

; ---------------------------------------------------------------------------
; CopyTilesToVRAM: copies GameTiles from ROM to VRAM, doubling each byte.
; ---------------------------------------------------------------------------
CopyTilesToVRAM:
  ld hl, GameTiles
  ld de, STARTOF(VRAM)
  ld bc, GameTilesEnd - GameTiles
.loop:
  ld a, [hl+]
  ld [de], a
  inc de
  ld [de], a
  inc de
  dec bc
  ld a, b
  or c
  jr nz, .loop
  ret

; ---------------------------------------------------------------------------
; UpdateOAM: writes the player sprite directly to hardware OAM entry 0.
; Must be called during VBlank (PPU not accessing OAM).
;
; OAM Y = (wPlayerY + MAP_DISPLAY_ROW) * 8 + 16
; OAM X = (wPlayerX + MAP_DISPLAY_COL) * 8 + 8
; ---------------------------------------------------------------------------
UpdateOAM:
  ld hl, STARTOF(OAM)

  ld a, [wPlayerY]
  add MAP_DISPLAY_ROW
  add a
  add a
  add a
  add 16
  ld [hl+], a

  ld a, [wPlayerX]
  add MAP_DISPLAY_COL
  add a
  add a
  add a
  add 8
  ld [hl+], a

  ld [hl], TILE_PLAYER
  inc hl
  ld [hl], 0
  ret

; ---------------------------------------------------------------------------
; UpdateGameState: processes one frame of input and game logic.
; Priority order: Start > A > B > Right > Left > Up > Down.
;
; Branches that trigger a level transition use pop hl to discard the
; return address before jumping, keeping the stack balanced on re-entry.
; ---------------------------------------------------------------------------
UpdateGameState:
  ; Start: restart current level
  ld a, [current]
  and PADB_START
  jr z, .checkAKey
  pop hl
  jp StartLevel

.checkAKey:
  ; A: advance to next level (clamped at LEVEL_COUNT-1)
  ld a, [current]
  and PADB_A
  jr z, .checkBKey
  ld a, [wCurrentLevel]
  inc a
  cp LEVEL_COUNT
  jr nc, .checkBKey       ; already at last level, ignore
  ld [wCurrentLevel], a
  pop hl
  jp StartLevel

.checkBKey:
  ; B: go back to previous level (clamped at 0)
  ld a, [current]
  and PADB_B
  jr z, .checkRight
  ld a, [wCurrentLevel]
  and a
  jr z, .checkRight       ; already at first level, ignore
  dec a
  ld [wCurrentLevel], a
  pop hl
  jp StartLevel

.checkRight:
  ld a, [current]
  and PADB_RIGHT
  jr z, .checkLeft
  ld a, [wPlayerX]
  inc a
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  call TryMove
  jr .checkWin

.checkLeft:
  ld a, [current]
  and PADB_LEFT
  jr z, .checkUp
  ld a, [wPlayerX]
  dec a
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  call TryMove
  jr .checkWin

.checkUp:
  ; Upward movement is allowed when:
  ;   (a) the target tile is TILE_STAIRS, OR
  ;   (b) the player is currently standing on TILE_STAIRS
  ld a, [current]
  and PADB_UP
  jr z, .checkDown
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  dec a
  ld e, a
  push de
  call GetTileAtXY        ; A = tile at (playerX, playerY-1)
  pop de
  cp TILE_STAIRS
  jr z, .doUpMove

  push de
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  call GetTileAtXY        ; A = tile at player's current position
  pop de
  cp TILE_STAIRS
  jr nz, .checkDown

.doUpMove:
  call TryMove
  jr .checkWin

.checkDown:
  ld a, [current]
  and PADB_DOWN
  jr z, .checkWin
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  inc a
  ld e, a
  call TryMove

.checkWin:
  ; Win condition: all monsters and ghosts have been defeated
  ld a, [wMonsterCount]
  and a
  ret nz

  ; Level cleared: advance to next level
  ld a, [wCurrentLevel]
  inc a
  ld [wCurrentLevel], a
  pop hl
  jp StartLevel

; ---------------------------------------------------------------------------
; ResetBG: fills the entire 32x32 background tilemap with TILE_NOTHING.
; ---------------------------------------------------------------------------
ResetBG:
  ld hl, TILEMAP0
  ld bc, 1024
.loop:
  ld [hl], TILE_NOTHING
  inc hl
  dec bc
  ld a, b
  or c
  jr nz, .loop
  ret

; ---------------------------------------------------------------------------
; DrawString: copies B tile IDs from address DE into tilemap at HL.
; Input: HL = tilemap destination, DE = string in ROM, B = length
; ---------------------------------------------------------------------------
DrawString:
.loop:
  ld a, [de]
  ld [hl+], a
  inc de
  dec b
  jr nz, .loop
  ret

;---------------------------------------------------------------------
; readKeys: reads all 8 buttons and stores results in WRAM.
;
; Output:
;   b        = raw state (all currently held buttons)
;   c        = rising edge (buttons newly pressed this frame)
;   [current]  = same as c
;   [previous] = updated to current raw state (do not touch externally)
;
; Bit layout of b / c / [current]:
;   down up left right start select B A
;   7    6   5    4     3     2      1 0
;---------------------------------------------------------------------
readKeys:
  ld    a, $20
  ldh   [rP1], a
  ldh   a, [rP1] :: ldh a, [rP1]
  cpl
  and   $0F
  swap  a
  ld    b, a

  ld    a, $10
  ldh   [rP1], a
  ldh   a, [rP1] :: ldh a, [rP1] :: ldh a, [rP1]
  ldh   a, [rP1] :: ldh a, [rP1] :: ldh a, [rP1]
  cpl
  and   $0F
  or    b
  ld    b, a

  ; Rising-edge detection: bits that changed from 0 to 1
  ld    a, [previous]
  xor   b
  and   b
  ld    [current], a
  ld    c, a
  ld    a, b
  ld    [previous], a

  ld    a, $30
  ldh   [rP1], a
  ret

; ---------------------------------------------------------------------------
; GetTileAtXY: returns the tile ID at map position (D, E) from wMapBuffer.
; Offset = E * MAP_COLS + D  (E*12 = E*8 + E*4)
;
; Input:  D = X (column), E = Y (row)
; Output: A = tile ID, HL = pointer into wMapBuffer
; Preserves: BC, DE
; ---------------------------------------------------------------------------
GetTileAtXY:
  push bc
  push de
  ld a, e
  add a
  add a
  ld b, a
  add a
  add b
  add d
  ld c, a
  ld b, 0
  ld hl, wMapBuffer
  add hl, bc
  ld a, [hl]
  pop de
  pop bc
  ret

; ---------------------------------------------------------------------------
; UpdateOneTile: writes tile A at logical position (D, E) into wMapBuffer,
; and sets wMapDirty to trigger a full redraw over the following VBlanks.
;
; Input:  A = new tile ID, D = X, E = Y
; Preserves: BC, DE
; ---------------------------------------------------------------------------
UpdateOneTile:
  push af
  call GetTileAtXY        ; HL = pointer to (D,E) in wMapBuffer
  pop af
  ld [hl], a

  ld a, 1
  ld [wMapDirty], a
  ret

; ---------------------------------------------------------------------------
; DrawMapToBackground: copies the full wMapBuffer to the background tilemap.
; Must be called while the PPU is off (from StartLevel).
; ---------------------------------------------------------------------------
DrawMapToBackground:
  ld b, 0                 ; start at row 0
  ld c, MAP_ROWS          ; copy every row
  ; fall through into DrawMapRows

; ---------------------------------------------------------------------------
; DrawMapRows: copies a horizontal band of the map into the background tilemap.
;
; Input:  B = start row (0..MAP_ROWS-1), C = number of rows to copy
; ---------------------------------------------------------------------------
DrawMapRows:
  push bc

  ; DE = wMapBuffer + startRow * MAP_COLS
  ld a, b
  add a                   ; *2
  add a                   ; *4
  ld e, a                 ; e = startRow * 4
  add a                   ; *8
  add e                   ; *12
  add LOW(wMapBuffer)
  ld e, a
  ld a, 0
  adc HIGH(wMapBuffer)
  ld d, a

  ; HL = TILEMAP0 + (MAP_DISPLAY_ROW + startRow) * 32 + MAP_DISPLAY_COL
  ld h, 0
  ld l, b
  add hl, hl              ; *2
  add hl, hl              ; *4
  add hl, hl              ; *8
  add hl, hl              ; *16
  add hl, hl              ; *32
  ld bc, TILEMAP0 + MAP_DISPLAY_ROW * 32 + MAP_DISPLAY_COL
  add hl, bc

  pop bc
  ld b, c                 ; B = number of rows to copy

.rowLoop:
  ld c, MAP_COLS
.colLoop:
  ld a, [de]
  ld [hl+], a
  inc de
  dec c
  jr nz, .colLoop

  ; Skip 20 unused columns to reach the next tilemap row
  ld a, l
  add 32 - MAP_COLS
  ld l, a
  jr nc, .noCarry
  inc h
.noCarry:
  dec b
  jr nz, .rowLoop
  ret

;------------------------------------------------------------------
; TryMove: attempts to move the player to tile (D, E).
; Handles: NOTHING/STAIRS (free move), SAND (dig), MONSTER/GHOST (kill),
;          ROCK (push if space behind), WALL (blocked).
; After a successful move, runs gravity for all tiles and the player.
;
; Input: D = target X, E = target Y
;------------------------------------------------------------------
TryMove:
  ld a, d
  ld [wTargetX], a
  ld a, e
  ld [wTargetY], a

  call GetTileAtXY
  cp TILE_NOTHING
  jr z, .doMove
  cp TILE_STAIRS
  jr z, .doMove

  cp TILE_SAND
  jr nz, .checkMonster
  ; Only horizontal movement can dig sand
  ld a, [wTargetY]
  ld b, a
  ld a, [wPlayerY]
  cp b
  jp nz, .blocked
  ld a, TILE_NOTHING
  call UpdateOneTile
  jr .doMove

.checkMonster:
  cp TILE_MONSTER
  jr z, .killEnemy
  cp TILE_GHOST
  jr z, .killEnemy
  jr .checkRock

.killEnemy:
  ; Only horizontal attacks can defeat enemies
  ld a, [wTargetY]
  ld b, a
  ld a, [wPlayerY]
  cp b
  jr nz, .blocked
  ld a, TILE_NOTHING
  call UpdateOneTile
  ld a, [wMonsterCount]
  dec a
  ld [wMonsterCount], a
  jr .doMove

.checkRock:
  cp TILE_ROCK
  jr nz, .blocked

  ; Compute the cell behind the rock in the push direction
  ld a, [wTargetX]
  ld b, a
  ld a, [wPlayerX]
  ld c, a
  ld a, b
  sub c
  add b
  ld b, a                 ; B = behind_X

  ld a, [wTargetY]
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  ld a, d
  sub e
  add d
  ld c, a                 ; C = behind_Y

  ld d, b
  ld e, c
  call GetTileAtXY
  cp TILE_NOTHING
  jr nz, .blocked

  ld a, TILE_ROCK
  call UpdateOneTile      ; place rock at the cell behind

  ld a, [wTargetX]
  ld d, a
  ld a, [wTargetY]
  ld e, a
  ld a, TILE_NOTHING
  call UpdateOneTile      ; clear the rock's original cell

  ; After pushing, run gravity (player stays in place)
  call ApplyGravityToAll
  call ApplyGravityToPlayer
  call ApplyGravityToAll
  ret

.doMove:
  ld a, [wTargetX]
  ld [wPlayerX], a
  ld a, [wTargetY]
  ld [wPlayerY], a

  call ApplyGravityToAll
  call ApplyGravityToPlayer
  call ApplyGravityToAll
  ret

.blocked:
  ret

; ---------------------------------------------------------------------------
; ApplyGravityToPlayer: drops the player while the tile below is empty.
; ---------------------------------------------------------------------------
ApplyGravityToPlayer:
.loop:
  ; No falling if standing on stairs
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  push de
  call GetTileAtXY
  pop de
  cp TILE_STAIRS
  ret z

  ; Check tile directly below
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  inc a
  ld e, a
  push de
  call GetTileAtXY
  pop de
  cp TILE_NOTHING
  ret nz
  ld a, e
  ld [wPlayerY], a
  jr .loop

; ---------------------------------------------------------------------------
; ApplyGravityToAll: scans the map bottom-to-top, dropping ROCK and MONSTER
; tiles one row per pass. Repeats until no tile moves.
; ---------------------------------------------------------------------------
ApplyGravityToAll:
.outerLoop:
  ld b, 0
  ld c, MAP_ROWS - 2
.rowLoop:
  ld d, 0
.colLoop:
  ld e, c
  push bc
  push de
  call GetTileAtXY
  pop de
  pop bc

  cp TILE_ROCK
  jr z, .isFalling
  cp TILE_MONSTER
  jr z, .isFalling
  jr .nextCol

.isFalling:
  ld [wFallingTile], a

  push bc
  push de
  ld a, e
  inc a
  ld e, a
  call GetTileAtXY
  pop de
  pop bc

  cp TILE_NOTHING
  jr nz, .nextCol
  ; Do not drop onto the player's position
  ld a, e
  inc a
  ld h, a
  ld a, [wPlayerY]
  cp h
  jr nz, .doDrop
  ld a, [wPlayerX]
  cp d
  jr z, .nextCol

.doDrop:
  push bc
  push de
  ld a, TILE_NOTHING
  call UpdateOneTile
  ld a, e
  inc a
  ld e, a
  ld a, [wFallingTile]
  call UpdateOneTile
  pop de
  pop bc
  ld b, 1

.nextCol:
  inc d
  ld a, d
  cp MAP_COLS
  jr nz, .colLoop

  ld a, c
  and a
  jr z, .passEnd
  dec c
  jr .rowLoop

.passEnd:
  ld a, b
  and a
  jr nz, .outerLoop
  ret

; ---------------------------------------------------------------------------
; LoadLevel: copies level wCurrentLevel from ROM into wMapBuffer.
; Uses the fact that all levels have the same size (MAP_SIZE bytes), so the
; address is computed as: Levels + wCurrentLevel * MAP_SIZE.
; Scans the buffer to count monsters/ghosts (-> wMonsterCount) and locate
; the player tile (-> wPlayerX, wPlayerY), replacing it with TILE_NOTHING.
; ---------------------------------------------------------------------------
LoadLevel:
  ; HL = Levels + wCurrentLevel * MAP_SIZE
  ; Computed as: start at Levels, add MAP_SIZE once per level index.
  ld a, [wCurrentLevel]
  ld hl, Levels
  or a
  jr z, .copyStart        ; level 0: no offset needed
  ld de, MAP_SIZE
.offsetLoop:
  add hl, de
  dec a
  jr nz, .offsetLoop

.copyStart:
  ld de, wMapBuffer
  ld b, MAP_SIZE
  xor a
  ld [wMonsterCount], a

.copyLoop:
  ld a, [hl+]
  ld [de], a

  cp TILE_MONSTER
  jr z, .countEnemy
  cp TILE_GHOST
  jr nz, .nextTile
.countEnemy:
  push af
  ld a, [wMonsterCount]
  inc a
  ld [wMonsterCount], a
  pop af

.nextTile:
  inc de
  dec b
  jr nz, .copyLoop

  ; Find and remove the player tile; extract (X, Y) from its linear index
  ld hl, wMapBuffer
  ld b, MAP_SIZE
  ld c, 0
.findPlayerLoop:
  ld a, [hl]
  cp TILE_PLAYER
  jr z, .foundPlayer
  inc hl
  inc c
  dec b
  jr nz, .findPlayerLoop
  jr .playerDone

.foundPlayer:
  ; Y = C / MAP_COLS, X = C mod MAP_COLS
  ld a, c
  ld b, 0
.divideLoop:
  cp MAP_COLS
  jr c, .divideDone
  sub MAP_COLS
  inc b
  jr .divideLoop
.divideDone:
  ld [wPlayerX], a
  ld a, b
  ld [wPlayerY], a
  ld [hl], TILE_NOTHING

.playerDone:
  ret

; ====================================================================
; SECTION: DATA
; ====================================================================
SECTION "Data", ROM0

TitleStr:
  db "CATRAP"
.end

PressStr:
  db "PRESS ANY KEY"
.end

EndingStr:
  db "CONGRATULATIONS"
.end

; ---------------------------------------------------------------------------
; GameTiles: 8 bytes per tile, stored in ROM.
; CopyTilesToVRAM doubles each byte into 2bpp VRAM format.
;
; Tile layout:
;   ID 0  TILE_NOTHING : blank
;   ID 1  TILE_STAIRS  : staircase
;   ID 2  TILE_MONSTER : monster
;   ID 3  TILE_ROCK    : rock
;   ID 4  TILE_SAND    : sand (checkerboard)
;   ID 5  TILE_WALL    : solid block
;   ID 6  TILE_GHOST   : ghost
;   ID 7  TILE_PLAYER  : player
;   ID 8-17            : digit glyphs '0'-'9'
;   ID 18-43           : letter glyphs 'A'-'Z' (used by DrawString / CHARMAP)
; ---------------------------------------------------------------------------
GameTiles:
  db $00,$00,$00,$00,$00,$00,$00,$00  ; Tile 0: NOTHING
  db $00,$FF,$00,$FF,$00,$FF,$00,$FF  ; Tile 1: STAIRS
  db $3C,$42,$5A,$42,$42,$5A,$42,$3C  ; Tile 2: MONSTER
  db $3C,$42,$81,$81,$81,$81,$42,$3C  ; Tile 3: ROCK
  db $AA,$55,$AA,$55,$AA,$55,$AA,$55  ; Tile 4: SAND
  db $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF  ; Tile 5: WALL
  db $3C,$7E,$DB,$FF,$FF,$FF,$A5,$A5  ; Tile 6: GHOST
  db $81,$42,$3C,$5A,$7E,$42,$42,$3C  ; Tile 7: PLAYER
  db $00,$3C,$66,$66,$66,$66,$3C,$00  ; Tile  8: '0'
  db $00,$18,$38,$18,$18,$18,$3C,$00  ; Tile  9: '1'
  db $00,$3C,$4E,$0E,$3C,$70,$7E,$00  ; Tile 10: '2'
  db $00,$7C,$0E,$3C,$0E,$0E,$7C,$00  ; Tile 11: '3'
  db $00,$3C,$6C,$4C,$4E,$7E,$0C,$00  ; Tile 12: '4'
  db $00,$7C,$60,$7C,$0E,$4E,$3C,$00  ; Tile 13: '5'
  db $00,$3C,$60,$7C,$66,$66,$3C,$00  ; Tile 14: '6'
  db $00,$7E,$06,$0C,$18,$38,$38,$00  ; Tile 15: '7'
  db $00,$3C,$4E,$3C,$4E,$4E,$3C,$00  ; Tile 16: '8'
  db $00,$3C,$4E,$4E,$3E,$0E,$3C,$00  ; Tile 17: '9'
  db $00,$3C,$4E,$4E,$7E,$4E,$4E,$00  ; Tile 18: 'A'
  db $00,$7C,$66,$7C,$66,$66,$7C,$00  ; Tile 19: 'B'
  db $00,$3C,$66,$60,$60,$66,$3C,$00  ; Tile 20: 'C'
  db $00,$7C,$4E,$4E,$4E,$4E,$7C,$00  ; Tile 21: 'D'
  db $00,$7E,$60,$7C,$60,$60,$7E,$00  ; Tile 22: 'E'
  db $00,$7E,$60,$60,$7C,$60,$60,$00  ; Tile 23: 'F'
  db $00,$3C,$66,$60,$6E,$66,$3E,$00  ; Tile 24: 'G'
  db $00,$46,$46,$7E,$46,$46,$46,$00  ; Tile 25: 'H'
  db $00,$3C,$18,$18,$18,$18,$3C,$00  ; Tile 26: 'I'
  db $00,$1E,$0C,$0C,$6C,$6C,$38,$00  ; Tile 27: 'J'
  db $00,$66,$6C,$78,$78,$6C,$66,$00  ; Tile 28: 'K'
  db $00,$60,$60,$60,$60,$60,$7E,$00  ; Tile 29: 'L'
  db $00,$46,$6E,$7E,$56,$46,$46,$00  ; Tile 30: 'M'
  db $00,$46,$66,$76,$5E,$4E,$46,$00  ; Tile 31: 'N'
  db $00,$3C,$66,$66,$66,$66,$3C,$00  ; Tile 32: 'O'
  db $00,$7C,$66,$66,$7C,$60,$60,$00  ; Tile 33: 'P'
  db $00,$3C,$62,$62,$6A,$64,$3A,$00  ; Tile 34: 'Q'
  db $00,$7C,$66,$66,$7C,$68,$66,$00  ; Tile 35: 'R'
  db $00,$3C,$60,$3C,$0E,$4E,$3C,$00  ; Tile 36: 'S'
  db $00,$7E,$18,$18,$18,$18,$18,$00  ; Tile 37: 'T'
  db $00,$46,$46,$46,$46,$4E,$3C,$00  ; Tile 38: 'U'
  db $00,$46,$46,$46,$46,$2C,$18,$00  ; Tile 39: 'V'
  db $00,$46,$46,$56,$7E,$6E,$46,$00  ; Tile 40: 'W'
  db $00,$46,$2C,$18,$38,$64,$42,$00  ; Tile 41: 'X'
  db $00,$66,$66,$3C,$18,$18,$18,$00  ; Tile 42: 'Y'
  db $00,$7E,$0E,$1C,$38,$70,$7E,$00  ; Tile 43: 'Z'
GameTilesEnd:

; Level data: 12x12 tile IDs, row-major, all levels stored contiguously.
; LoadLevel computes the address as: Levels + wCurrentLevel * MAP_SIZE (144).
; Encoding: 0=Nothing 1=Stairs 2=Monster 3=Rock 4=Sand 5=Wall 6=Ghost 7=Player

Levels:

; Level 0
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,7,4,0,3,0,0,2,0,0,0,5
  db 5,5,5,5,5,0,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 1
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,0,2,0,0,3,0,0,0,0,5
  db 5,0,4,4,0,0,3,0,0,0,0,5
  db 5,1,5,5,0,0,3,0,0,2,0,5
  db 5,1,5,5,5,5,5,0,5,5,5,5
  db 5,1,0,0,0,0,5,0,5,5,5,5
  db 5,1,0,0,7,0,5,0,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 2
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,3,1,5,5,5
  db 5,5,5,5,5,5,5,2,1,5,5,5
  db 5,5,5,5,5,5,5,3,1,5,5,5
  db 5,5,0,0,0,0,0,2,1,5,5,5
  db 5,5,0,6,6,6,6,2,1,5,5,5
  db 5,5,0,0,0,0,0,3,1,5,5,5
  db 5,5,0,5,5,5,5,5,1,5,5,5
  db 5,5,0,0,0,7,0,0,1,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 3
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,5,0,0,0,5
  db 5,6,4,1,0,0,0,5,1,2,0,5
  db 5,4,4,1,5,0,0,5,1,5,5,5
  db 5,0,0,1,0,5,0,0,1,0,0,5
  db 5,0,0,1,0,0,5,0,1,0,0,5
  db 5,0,0,1,0,0,0,5,0,0,0,5
  db 5,0,5,1,0,0,0,0,5,5,5,5
  db 5,0,0,1,3,0,0,0,0,0,0,5
  db 5,0,0,1,4,3,0,0,2,0,3,5
  db 5,7,0,1,5,5,0,0,1,0,2,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 4
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,6,0,3,0,5
  db 5,0,0,0,0,3,2,0,4,4,1,5
  db 5,0,0,0,0,5,5,5,5,5,1,5
  db 5,0,0,0,0,0,3,0,0,0,1,5
  db 5,0,0,0,0,2,4,0,0,0,1,5
  db 5,0,0,0,0,5,5,5,1,0,1,5
  db 5,0,0,0,0,0,0,0,1,0,1,5
  db 5,0,0,6,0,0,0,0,1,0,1,5
  db 5,0,0,0,0,0,0,0,1,0,1,5
  db 5,7,0,0,0,0,2,0,1,0,1,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,0,0,0,0,0,3,0,0,0,5
  db 5,5,0,5,5,5,1,1,1,1,1,5
  db 5,5,0,0,0,0,0,0,0,0,1,5
  db 5,5,0,0,0,0,0,0,0,0,1,5
  db 5,4,0,0,0,0,0,0,0,0,1,5
  db 5,4,0,0,0,0,0,0,0,0,1,5
  db 5,4,0,0,0,0,0,0,0,0,1,5
  db 5,4,0,0,0,6,0,0,0,0,1,5
  db 5,5,5,5,0,0,0,0,0,0,1,5
  db 5,5,5,5,3,7,0,0,0,0,1,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 6
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,3,0,0,0,5,0,0,0,0,5
  db 5,0,3,6,0,0,5,0,0,0,2,5
  db 5,1,4,0,0,3,5,5,1,5,5,5
  db 5,1,3,0,0,3,0,0,1,5,5,5
  db 5,1,3,0,0,3,0,0,1,5,5,5
  db 5,1,4,0,0,4,0,0,1,5,5,5
  db 5,1,0,0,5,5,0,0,1,5,5,5
  db 5,1,0,7,5,5,0,0,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 7
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,3,0,5,0,0,0,0,0,5
  db 5,0,0,3,0,5,0,0,0,0,2,5
  db 5,1,4,3,0,5,5,1,5,5,5,5
  db 5,1,3,4,3,0,0,1,0,0,0,5
  db 5,1,3,0,3,0,0,1,0,0,0,5
  db 5,1,4,0,4,0,0,1,0,0,0,5
  db 5,1,0,0,5,0,0,0,0,0,0,5
  db 5,1,7,0,5,0,0,0,0,0,0,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 8
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,0,0,0,5,5
  db 5,0,0,0,0,0,0,0,3,0,5,5
  db 5,1,5,2,2,2,2,2,3,2,5,5
  db 5,1,7,4,4,4,4,4,4,4,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

; Level 9
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,0,0,0,0,0,0,0,5
  db 5,5,5,5,0,0,0,3,0,0,0,5
  db 5,5,5,5,0,0,0,3,0,0,0,5
  db 5,5,5,5,0,0,1,2,0,0,0,5
  db 5,5,5,5,0,0,1,2,0,0,6,5
  db 5,5,5,5,0,0,1,6,0,0,6,5
  db 5,0,0,0,0,0,1,0,6,2,0,5
  db 5,0,0,0,0,0,1,2,0,2,0,5
  db 5,0,0,0,0,0,1,5,6,6,0,5
  db 5,0,0,7,0,0,1,0,2,0,0,5
  db 5,5,5,5,5,5,5,5,5,5,5,5