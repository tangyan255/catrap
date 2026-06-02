; ====================================================================
; PROJECT: Catrap (Game Boy Port)
; RESTRICTIONS: NO DMA, NO INTERRUPTS, NO RST INSTRUCTIONS
; TEAM NUMBERS: XIAOKUN WANG 999025521, ENHAO HU 999025208
; ====================================================================

INCLUDE "hardware.inc"

; ====================================================================
; CONSTANTS
; ====================================================================
DEF OBJCOUNT        EQU 40
DEF VRAM_BLOCK1     EQU $8000

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

DEF LEVEL_COUNT     EQU 3

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
current:        db          ; readKeys internal: rising-edge result
ShadowOAM:      ds 40 * 4
wKeyHeld:       db
wKeyPressed:    db
; wMapDirty: set to 1 by UpdateOneTile whenever wMapBuffer changes.
; DrawMapToBackground is only called during VBlank when this flag is set,
; keeping VRAM writes strictly inside VBlank.
wMapDirty:      db

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
  call ClearShadowOAM

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
  call ClearShadowOAM
  call CopyShadowOAMtoOAM

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
  call ClearShadowOAM

  call LoadLevel
  call DrawMapToBackground    ; initial draw while PPU is off, always safe

  xor a
  ld [wKeyPressed], a
  ld [wKeyHeld], a
  ld [wMapDirty], a           ; map was just drawn; nothing pending

  ld a, LCDC_ON | LCDC_OBJ_ON | LCDC_BG_ON | LCDC_BLOCK01
  ld [rLCDC], a

; ---------------------------------------------------------------------------
; MainLoop: input -> logic -> sprites -> VBlank -> VRAM/OAM -> repeat.
;
; VRAM and OAM are only written inside VBlank (after WaitVBlank):
;   - DrawMapToBackground: redraws map tiles, only when wMapDirty is set.
;   - CopyShadowOAMtoOAM:  copies player sprite to hardware OAM.
; ---------------------------------------------------------------------------
MainLoop:
  call readKeys
  call UpdateGameState        ; outside VBlank: logic only
  call Convert                ; outside VBlank: update ShadowOAM

  call WaitVBlank

  ; Redraw background tilemap only when the map actually changed
  ld a, [wMapDirty]
  and a
  jr z, .skipDraw
  call DrawMapToBackground    ; inside VBlank: safe VRAM write
  xor a
  ld [wMapDirty], a
.skipDraw:
  call CopyShadowOAMtoOAM     ; inside VBlank: safe OAM write
  jp MainLoop

; ---------------------------------------------------------------------------
; EndingScreen: congratulations message, then back to title on any key.
; ---------------------------------------------------------------------------
EndingScreen:
  call SafeTurnOffLCD
  call ResetBG
  call ClearShadowOAM
  call CopyShadowOAMtoOAM

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
; Turning off the LCD outside VBlank can damage real hardware.
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
; ClearShadowOAM: zeroes all 160 bytes of ShadowOAM (Y=0 hides sprites).
; ---------------------------------------------------------------------------
ClearShadowOAM:
  ld hl, ShadowOAM
  ld b, 160
  xor a
.clear:
  ld [hl+], a
  dec b
  jr nz, .clear
  ret

; ---------------------------------------------------------------------------
; WaitKey: polls readKeys until at least one button has a rising edge.
; ---------------------------------------------------------------------------
WaitKey:
.loop:
  call readKeys
  ld a, [wKeyPressed]
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
; CopyTilesToVRAM: copies GameTiles from ROM to VRAM, doubling each byte
; to fill both bitplanes of the Game Boy's 2bpp tile format.
; ---------------------------------------------------------------------------
CopyTilesToVRAM:
  ld hl, GameTiles
  ld de, VRAM_BLOCK1
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
; CopyShadowOAMtoOAM: copies 160-byte ShadowOAM to hardware OAM.
; Loop unrolled 4x to fit within the ~4560-cycle VBlank window.
; Must only be called during VBlank.
; ---------------------------------------------------------------------------
CopyShadowOAMtoOAM:
  ld hl, ShadowOAM
  ld de, STARTOF(OAM)
  ld b, OBJCOUNT
.loop:
  ld a, [hl+]
  ld [de], a
  inc e
  ld a, [hl+]
  ld [de], a
  inc e
  ld a, [hl+]
  ld [de], a
  inc e
  ld a, [hl+]
  ld [de], a
  inc e
  dec b
  jr nz, .loop
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
  ld a, [wKeyPressed]
  and PADB_START
  jr z, .checkAKey
  pop hl
  jp StartLevel

.checkAKey:
  ; A: advance to next level (clamped at LEVEL_COUNT-1)
  ld a, [wKeyPressed]
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
  ld a, [wKeyPressed]
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
  ld a, [wKeyPressed]
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
  ld a, [wKeyPressed]
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
  ;       (i.e. climbing out the top of a ladder onto open space)
  ld a, [wKeyPressed]
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
  jr z, .doUpMove         ; target is a ladder -> always allow
 
  ; target is not a ladder; only allow if the player stands on one
  push de
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  call GetTileAtXY        ; A = tile at player's current position
  pop de
  cp TILE_STAIRS
  jr nz, .checkDown       ; not on a ladder -> block upward move
  
.doUpMove:
  call TryMove
  jr .checkWin  

.checkDown:
  ld a, [wKeyPressed]
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
  ret nz                  ; enemies remain, keep playing

  ; Level cleared: advance to next level and jump directly to StartLevel
  ld a, [wCurrentLevel]
  inc a
  ld [wCurrentLevel], a
  pop hl
  jp StartLevel

; ---------------------------------------------------------------------------
; Convert: translates player logical coordinates to OAM pixel coordinates
; and writes the player sprite to the first ShadowOAM entry.
;
; OAM Y = (wPlayerY + MAP_DISPLAY_ROW) * 8 + 16
; OAM X = (wPlayerX + MAP_DISPLAY_COL) * 8 + 8
; ---------------------------------------------------------------------------
Convert:
  ld hl, ShadowOAM

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
;   wKeyHeld    = raw state (all currently held buttons)
;   wKeyPressed = rising edge (buttons newly pressed this frame)
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

  ld    a, b
  ld    [wKeyHeld], a
  ld    a, c
  ld    [wKeyPressed], a

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
; and sets wMapDirty so the next VBlank redraws the full tilemap.
; VRAM is NOT touched here.
;
; Input:  A = new tile ID, D = X, E = Y
; Preserves: BC, DE
; ---------------------------------------------------------------------------
UpdateOneTile:
  push af
  call GetTileAtXY        ; HL = pointer to (D,E) in wMapBuffer
  pop af
  ld [hl], a              ; write new tile ID to logical buffer

  ld a, 1
  ld [wMapDirty], a       ; signal that the background needs redrawing
  ret

; ---------------------------------------------------------------------------
; DrawMapToBackground: copies the full wMapBuffer into the background tilemap.
; Must be called during VBlank (or while PPU is off) to safely write VRAM.
;
; The play area starts at (MAP_DISPLAY_COL, MAP_DISPLAY_ROW) in the 32-wide
; tilemap. After each 12-column row, HL is advanced by 20 to skip the
; remaining columns (32 - 12 = 20).
; ---------------------------------------------------------------------------
DrawMapToBackground:
  ld de, wMapBuffer
  ld hl, TILEMAP0 + MAP_DISPLAY_ROW * 32 + MAP_DISPLAY_COL
  ld b, MAP_ROWS
.rowLoop:
  ld c, MAP_COLS
.colLoop:
  ld a, [de]
  ld [hl+], a
  inc de
  dec c
  jr nz, .colLoop

  ; Skip the 20 unused columns to reach the start of the next tilemap row
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
; Sets wMapDirty via UpdateOneTile whenever the map changes.
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

  ; Compute the cell behind the rock in the push direction:
  ; behind_X = target_X + (target_X - player_X)
  ; behind_Y = target_Y + (target_Y - player_Y)
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
  call UpdateOneTile      ; place rock at the cell behind (D=behind_X, E=behind_Y)

  ld a, [wTargetX]
  ld d, a
  ld a, [wTargetY]
  ld e, a
  ld a, TILE_NOTHING
  call UpdateOneTile      ; clear the rock's original cell

  ; After pushing a rock the player stays in place;
  ; run gravity so displaced rocks above can fall.
  call ApplyGravityToAll
  call ApplyGravityToPlayer
  ret

.doMove:
  ld a, [wTargetX]
  ld [wPlayerX], a
  ld a, [wTargetY]
  ld [wPlayerY], a

  call ApplyGravityToAll
  call ApplyGravityToPlayer
  ret

.blocked:
  ret

; ---------------------------------------------------------------------------
; ApplyGravityToPlayer: drops the player while the tile below is empty.
; ---------------------------------------------------------------------------
ApplyGravityToPlayer:
.loop:
  ; If the player's current tile is TILE_STAIRS, gravity does not apply
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  ld e, a
  push de
  call GetTileAtXY        ; A = tile at player's current position
  pop de
  cp TILE_STAIRS
  ret z                   ; standing on a ladder -> no falling
 
  ; Check the tile directly below the player
  ld a, [wPlayerX]
  ld d, a
  ld a, [wPlayerY]
  inc a
  ld e, a
  push de
  call GetTileAtXY
  pop de
  cp TILE_NOTHING
  ret nz                  ; something solid below -> stop
  ld a, e
  ld [wPlayerY], a
  jr .loop

; ---------------------------------------------------------------------------
; ApplyGravityToAll: repeatedly scans the map bottom-to-top, dropping ROCK,
; MONSTER, and SAND tiles one row per pass. Repeats until no tile moves.
; GHOST tiles are not affected by gravity.
;
; Registers: B = movement flag, C = current row, D = current column
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
  cp TILE_SAND
  jr z, .isFalling
  jr .nextCol             ; GHOST and others are not affected by gravity

.isFalling:
  ld [wTargetX], a        ; temporarily save the tile type

  ; Check the tile directly below
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
  ; Do not drop onto the player's current position
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
  call UpdateOneTile      ; clear tile at (D, E)
  ld a, e
  inc a
  ld e, a
  ld a, [wTargetX]
  call UpdateOneTile      ; place tile at (D, E+1)
  pop de
  pop bc
  ld b, 1                 ; mark that at least one tile moved this pass

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
  jr nz, .outerLoop       ; repeat until no tile moved
  ret

; ---------------------------------------------------------------------------
; LoadLevel: copies level wCurrentLevel from ROM into wMapBuffer.
; Scans the buffer to count monsters/ghosts (-> wMonsterCount) and locate
; the player tile (-> wPlayerX, wPlayerY), replacing it with TILE_NOTHING.
; ---------------------------------------------------------------------------
LoadLevel:
  ld a, [wCurrentLevel]
  add a                   ; each LevelTable entry is 2 bytes (dw)
  ld hl, LevelTable
  ld d, 0
  ld e, a
  add hl, de
  ld a, [hl+]
  ld h, [hl]
  ld l, a                 ; HL = address of this level's data

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
  ; Y = C / MAP_COLS, X = C mod MAP_COLS (computed by repeated subtraction)
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

; LevelTable: 2-byte addresses pointing to each level's data block.
; Indexed by wCurrentLevel (each entry is a dw, so index * 2 to access).
LevelTable:
  dw Level0Data
  dw Level1Data
  dw Level2Data


; Level data: 12x12 tile IDs, row-major.
; Encoding: 0=Nothing 1=Stairs 2=Monster 3=Rock 4=Sand 5=Wall 6=Ghost 7=Player

Level0Data:
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,0,0,0,0,0,0,0,0,0,5
  db 5,0,4,0,0,0,0,0,0,0,0,5
  db 5,7,4,0,3,0,0,2,0,0,0,5
  db 5,5,5,5,5,0,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5
  db 5,5,5,5,5,5,5,5,5,5,5,5

Level1Data:
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
  
Level2Data:
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
  
