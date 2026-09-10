extends Node2D

enum GameState { MENU, PLAYING, WON, LOST }
enum NetState { IDLE, CAST, CATCH, MISS }

const KAYAK_SHEET = preload("res://assets/kayak-net-sprites-transparent.png")
const OBJECT_SHEET = preload("res://assets/river-object-sprites.png")
const RIVER_AMBIENCE = preload("res://assets/audio/river_ambience.wav")
const WATER_IMPACT = preload("res://assets/audio/water_impact.wav")
const COLLECT_SOUND = preload("res://assets/audio/collect.wav")
const VICTORY_SOUND = preload("res://assets/audio/victory.wav")
const FAILURE_SOUND = preload("res://assets/audio/failure.wav")

const SCREEN := Vector2(1152, 648)
const GAME_TIME := 85.0
const PLAYER_SPEED := 255.0
const MAX_HITS := 3
const HIT_TIME_PENALTY := 5.0
const OIL_CLEAR_BONUS := 10.0
const BOTTLE_TOTAL := 20
const OIL_RADIUS := 54.0
const OIL_CLEAN_RATE := 14.0
const FISH_CAGE := Rect2(960, 205, 150, 230)
const OIL_START_A := Vector2(690, 235)
const OIL_START_B := Vector2(680, 455)
const OIL_TARGET_A := Vector2(915, 265)
const OIL_TARGET_B := Vector2(915, 385)
const WATER := Color("#168aad")
const DEEP_WATER := Color("#0b6e91")
const CREAM := Color("#fff4d6")
const GREEN := Color("#7ae582")
const CORAL := Color("#ff6b6b")

var state := GameState.MENU
var player := Vector2(105, 330)
var direction := Vector2.RIGHT
var bottles: Array[Vector2] = []
var bottles_collected := 0
var time_left := GAME_TIME
var oil_cleanups := [0.0, 0.0]
var oil_centers := [OIL_START_A, OIL_START_B]
var fish_alive := true
var hit_count := 0
var wave_time := 0.0
var hit_cooldown := 0.0
var flash := 0.0
var notice := ""
var notice_time := 0.0
var end_reason := ""
var net_state := NetState.IDLE
var net_timer := 0.0
var pending_bottle := -1
var oil_clean_notified := [false, false]

var bottle_wave_one := [
	Vector2(135, 145), Vector2(255, 175), Vector2(375, 130), Vector2(500, 175), Vector2(610, 125),
	Vector2(165, 300), Vector2(305, 335), Vector2(445, 285), Vector2(565, 350), Vector2(620, 520)
]
var bottle_wave_two := [
	Vector2(120, 180), Vector2(245, 125), Vector2(370, 200), Vector2(505, 135), Vector2(610, 280),
	Vector2(145, 465), Vector2(280, 530), Vector2(415, 455), Vector2(540, 535), Vector2(635, 410)
]

var rock_spawns := [
	Vector2(220, 235), Vector2(360, 410), Vector2(510, 225),
	Vector2(255, 500), Vector2(475, 340), Vector2(570, 475)
]
var rocks: Array[Vector2] = []
var rock_speeds := [42.0, -34.0, 28.0, -46.0, 38.0, -30.0]

func _ready() -> void:
	get_window().title = "EcoMisión: Rescate en Kayak"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bottles.assign(bottle_wave_one)
	rocks.assign(rock_spawns)
	start_ambience()
	if "--self-test" in OS.get_cmdline_user_args():
		run_self_test()
	queue_redraw()


func start_ambience() -> void:
	var loop_stream := RIVER_AMBIENCE.duplicate() as AudioStreamWAV
	loop_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var audio_player := AudioStreamPlayer.new()
	audio_player.stream = loop_stream
	audio_player.volume_db = -18.0
	add_child(audio_player)
	audio_player.play()


func play_sound(stream: AudioStream, volume_db := 0.0, pitch_scale := 1.0) -> void:
	var audio_player := AudioStreamPlayer.new()
	audio_player.stream = stream
	audio_player.volume_db = volume_db
	audio_player.pitch_scale = pitch_scale
	audio_player.finished.connect(audio_player.queue_free)
	add_child(audio_player)
	audio_player.play()


func run_self_test() -> void:
	start_game()
	bottles_collected = 9
	assert(not oil_is_unlocked(0))
	bottles_collected = 10
	assert(oil_is_unlocked(0) and not oil_is_unlocked(1))
	bottles.clear()
	time_left = 50.0
	clean_oil(0, 100.0 / OIL_CLEAN_RATE)
	assert(oil_cleanups[0] >= 100.0 and bottles.size() == 10 and time_left == 60.0)
	start_game()
	bottles = [Vector2(1000, 100)]
	cast_net()
	resolve_net()
	assert(net_state == NetState.MISS and bottles.size() == 1)
	start_game()
	bottles = [player + direction * 92.0]
	cast_net()
	resolve_net()
	bottles_collected = BOTTLE_TOTAL
	bottles.clear()
	oil_cleanups = [100.0, 100.0]
	update_game(0.01)
	assert(state == GameState.WON)
	start_game()
	for index in range(3):
		hit_cooldown = 0.0
		hit_rock()
	assert(state == GameState.LOST and hit_count == MAX_HITS)
	start_game()
	time_left = 0.0
	update_game(0.01)
	assert(state == GameState.LOST)
	print("SELF_TEST_OK: desbloqueos, victoria y derrotas verificados")
	get_tree().quit()


func _process(delta: float) -> void:
	wave_time += delta
	flash = maxf(0.0, flash - delta)
	notice_time = maxf(0.0, notice_time - delta)
	if net_timer > 0.0:
		net_timer -= delta
		if net_timer <= 0.0:
			if net_state == NetState.CAST:
				resolve_net()
			else:
				net_state = NetState.IDLE
	if state == GameState.PLAYING:
		update_game(delta)
	queue_redraw()


func update_game(delta: float) -> void:
	time_left -= delta
	var elapsed := GAME_TIME - maxf(time_left, 0.0)
	var travel := clampf(elapsed / GAME_TIME, 0.0, 1.0)
	oil_centers[0] = OIL_START_A.lerp(OIL_TARGET_A, travel)
	oil_centers[1] = OIL_START_B.lerp(OIL_TARGET_B, travel)
	hit_cooldown = maxf(0.0, hit_cooldown - delta)
	move_obstacles(delta)

	var movement := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	).normalized()
	var previous := player

	if movement != Vector2.ZERO:
		direction = movement
		var speed := PLAYER_SPEED * (0.58 if get_touched_oil() >= 0 else 1.0)
		player += movement * speed * delta
		player.x = clampf(player.x, 28.0, SCREEN.x - 28.0)
		player.y = clampf(player.y, 94.0, SCREEN.y - 28.0)
	for rock in rocks:
		if player.distance_to(rock) < 29.0 and hit_cooldown <= 0.0:
			var push_direction := rock.direction_to(player)
			if push_direction == Vector2.ZERO:
				push_direction = Vector2.LEFT
			player = previous + push_direction * 44.0
			player.x = clampf(player.x, 28.0, SCREEN.x - 28.0)
			player.y = clampf(player.y, 94.0, SCREEN.y - 28.0)
			hit_rock()
			break

	var touched_oil := get_touched_oil()
	if touched_oil >= 0 and Input.is_key_pressed(KEY_SPACE):
		if oil_is_unlocked(touched_oil):
			clean_oil(touched_oil, delta)
		else:
			notice = "Necesitás %d botellas para limpiar este charco" % ((touched_oil + 1) * 10)
			notice_time = 0.2

	if bottles.is_empty() and all_oil_clean():
		finish_game(true, "¡El río quedó libre de residuos!")
	elif time_left <= 0.0:
		fish_alive = false
		finish_game(false, "Se acabó el tiempo: el petróleo alcanzó a los peces.")


func move_obstacles(delta: float) -> void:
	for index in rocks.size():
		rocks[index].x += rock_speeds[index] * delta
		if rocks[index].x > 620.0:
			rocks[index].x = 80.0
		elif rocks[index].x < 80.0:
			rocks[index].x = 620.0


func get_touched_oil() -> int:
	for index in oil_centers.size():
		if oil_cleanups[index] < 100.0 and player.distance_to(oil_centers[index]) < OIL_RADIUS + 34.0:
			return index
	return -1


func collected_bottles() -> int:
	return bottles_collected


func oil_is_unlocked(index: int) -> bool:
	return collected_bottles() >= (index + 1) * 10


func all_oil_clean() -> bool:
	return oil_cleanups[0] >= 100.0 and oil_cleanups[1] >= 100.0


func clean_oil(index: int, delta: float) -> void:
	var previous: float = oil_cleanups[index]
	oil_cleanups[index] = minf(100.0, oil_cleanups[index] + OIL_CLEAN_RATE * delta)
	notice = "Limpiando charco %d... %d%%" % [index + 1, int(oil_cleanups[index])]
	notice_time = 0.2
	if previous < 100.0 and oil_cleanups[index] >= 100.0 and not oil_clean_notified[index]:
		oil_clean_notified[index] = true
		time_left += OIL_CLEAR_BONUS
		notice = "¡Charco %d limpio! +10 segundos" % (index + 1)
		notice_time = 2.0
		play_sound(COLLECT_SOUND, -1.0, 0.82)
		if index == 0:
			bottles.assign(bottle_wave_two)


func hit_rock() -> void:
	if hit_cooldown > 0.0:
		return
	hit_cooldown = 1.15
	hit_count += 1
	time_left = maxf(0.0, time_left - HIT_TIME_PENALTY)
	flash = 0.35
	notice = "¡Golpe %d/%d! -5 segundos" % [hit_count, MAX_HITS]
	notice_time = 1.5
	play_sound(WATER_IMPACT, -5.0, 0.72)
	if hit_count >= MAX_HITS:
		finish_game(false, "El kayak recibió 3 golpes y quedó fuera de juego.")


func cast_net() -> void:
	if net_state != NetState.IDLE:
		return
	net_state = NetState.CAST
	net_timer = 0.18
	play_sound(WATER_IMPACT, -11.0, 1.32)
	pending_bottle = -1
	var target := player + direction * 70.0
	var best_distance := 48.0
	for index in bottles.size():
		var distance := bottles[index].distance_to(target)
		if distance < best_distance:
			best_distance = distance
			pending_bottle = index


func resolve_net() -> void:
	notice_time = 1.1
	if pending_bottle >= 0 and pending_bottle < bottles.size():
		bottles.remove_at(pending_bottle)
		bottles_collected += 1
		net_state = NetState.CATCH
		play_sound(COLLECT_SOUND, -2.0, 1.08)
		flash = 0.16
		notice = "+1 botella recuperada"
		if bottles_collected == 10:
			notice = "¡10 botellas! Ya podés limpiar el charco 1"
			notice_time = 2.0
		elif bottles_collected == BOTTLE_TOTAL:
			notice = "¡20 botellas! Ya podés limpiar el charco 2"
			notice_time = 2.0
	else:
		net_state = NetState.MISS
		notice = "La red no atrapó nada"
		play_sound(FAILURE_SOUND, -9.0, 1.25)
	net_timer = 0.42
	pending_bottle = -1


func start_game() -> void:
	state = GameState.PLAYING
	player = Vector2(105, 330)
	direction = Vector2.RIGHT
	bottles.assign(bottle_wave_one)
	bottles_collected = 0
	rocks.assign(rock_spawns)
	time_left = GAME_TIME
	oil_cleanups = [0.0, 0.0]
	oil_centers = [OIL_START_A, OIL_START_B]
	fish_alive = true
	oil_clean_notified = [false, false]
	hit_count = 0
	hit_cooldown = 0.0
	flash = 0.0
	notice = "Juntá 10 botellas por charco y limpiá ambos antes de que lleguen a los peces"
	notice_time = 3.2
	end_reason = ""
	net_state = NetState.IDLE
	net_timer = 0.0
	pending_bottle = -1
	play_sound(COLLECT_SOUND, -8.0, 0.9)


func finish_game(won: bool, reason: String) -> void:
	if state != GameState.PLAYING:
		return
	state = GameState.WON if won else GameState.LOST
	end_reason = reason
	play_sound(VICTORY_SOUND if won else FAILURE_SOUND, -1.5)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and state == GameState.PLAYING:
			var touched_oil := get_touched_oil()
			if touched_oil < 0 or not oil_is_unlocked(touched_oil):
				cast_net()
		elif event.keycode in [KEY_ENTER, KEY_SPACE] and state != GameState.PLAYING:
			start_game()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if state != GameState.PLAYING and Rect2(442, 492, 268, 58).has_point(event.position):
			start_game()


func _draw() -> void:
	draw_water()
	draw_shores()
	draw_fish_cage()
	for index in oil_centers.size():
		draw_oil(index)
	for rock in rocks:
		draw_rock(rock)
	for bottle in bottles:
		draw_bottle(bottle)
	draw_kayak()
	draw_hud()
	if state == GameState.MENU:
		draw_menu()
	elif state in [GameState.WON, GameState.LOST]:
		draw_end_screen()
	if flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(1, 1, 1, flash * 0.45))


func draw_water() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), WATER)
	for row in range(8):
		for column in range(12):
			var x := float(column * 108 - 30) + sin(wave_time * 1.5 + row) * 12.0
			var y := float(95 + row * 70) + cos(wave_time + column) * 5.0
			draw_arc(Vector2(x, y), 24.0, 0.15, 2.7, 18, Color(0.65, 0.94, 1.0, 0.22), 3.0)


func draw_shores() -> void:
	draw_colored_polygon(PackedVector2Array([Vector2.ZERO, Vector2(SCREEN.x, 0), Vector2(SCREEN.x, 76), Vector2(0, 92)]), Color("#e9c46a"))
	draw_colored_polygon(PackedVector2Array([Vector2(0, 0), Vector2(SCREEN.x, 0), Vector2(SCREEN.x, 38), Vector2(0, 50)]), Color("#588157"))
	for x in range(18, 1152, 72):
		draw_circle(Vector2(x, 56 + sin(float(x)) * 7.0), 13.0, Color("#3a5a40"))


func draw_oil(index: int) -> void:
	if oil_cleanups[index] >= 100.0:
		return
	var center: Vector2 = oil_centers[index]
	var remaining: float = 1.0 - oil_cleanups[index] / 100.0
	var radius := OIL_RADIUS * lerpf(0.38, 1.0, sqrt(remaining))
	draw_circle(center, radius * 0.82, Color(0.025, 0.025, 0.035, 0.72))
	var size := radius * 2.0
	draw_texture_rect_region(OBJECT_SHEET, Rect2(center - Vector2.ONE * size * 0.5, Vector2.ONE * size), Rect2(768, 512, 480, 512))
	draw_arc(center, radius, 0.0, TAU, 64, Color(0.55, 0.15, 0.72, 0.55), 3.0)
	var font := ThemeDB.fallback_font
	var label := ""
	if index == 1 and not oil_clean_notified[0]:
		label = "ETAPA 2 · LIMPIÁ EL CHARCO 1"
	elif oil_is_unlocked(index):
		label = "CHARCO %d · %d%%" % [index + 1, int(oil_cleanups[index])]
	else:
		label = "CHARCO %d · REQUIERE %d BOTELLAS" % [index + 1, (index + 1) * 10]
	var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, center + Vector2(-label_width * 0.5, -radius - 8), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, CREAM)
	if get_touched_oil() == index:
		draw_centered("MANTENÉ ESPACIO PARA LIMPIAR" if oil_is_unlocked(index) else "RECOLECTÁ LAS BOTELLAS NECESARIAS", 604, 18, CREAM)
		draw_rect(Rect2(376, 615, 400, 10), Color("#17324d"), true)
		draw_rect(Rect2(376, 615, 400.0 * oil_cleanups[index] / 100.0, 10), GREEN, true)


func draw_fish_cage() -> void:
	draw_rect(FISH_CAGE, Color(0.08, 0.42, 0.55, 0.46), true)
	draw_rect(FISH_CAGE, Color("#b7e4c7"), false, 4.0)
	for x in range(int(FISH_CAGE.position.x) + 16, int(FISH_CAGE.end.x), 24):
		draw_line(Vector2(x, FISH_CAGE.position.y), Vector2(x, FISH_CAGE.end.y), Color(0.72, 0.9, 0.82, 0.38), 2.0)
	for y in range(int(FISH_CAGE.position.y) + 18, int(FISH_CAGE.end.y), 24):
		draw_line(Vector2(FISH_CAGE.position.x, y), Vector2(FISH_CAGE.end.x, y), Color(0.72, 0.9, 0.82, 0.38), 2.0)
	var fish_positions := [Vector2(982, 238), Vector2(1062, 282), Vector2(995, 352), Vector2(1065, 404)]
	for index in fish_positions.size():
		var swim := Vector2(sin(wave_time * 1.7 + index) * 8.0, cos(wave_time * 1.3 + index) * 5.0)
		draw_fish(fish_positions[index] + swim, index % 2 == 0)


func draw_fish(at: Vector2, faces_right: bool) -> void:
	var facing := 1.0 if faces_right else -1.0
	draw_set_transform(at, 0.0, Vector2(facing, 1.0))
	if not fish_alive:
		draw_circle(Vector2(15, 0), 8.0, Color("#d9e2ec"), false, 3.0)
		draw_line(Vector2(-24, 0), Vector2(8, 0), Color("#d9e2ec"), 3.0)
		for rib_x in range(-18, 7, 7):
			draw_line(Vector2(rib_x, -8), Vector2(rib_x + 4, 8), Color("#d9e2ec"), 2.0)
		draw_colored_polygon(PackedVector2Array([Vector2(-24, 0), Vector2(-36, -10), Vector2(-36, 10)]), Color("#d9e2ec"))
		draw_line(Vector2(12, -4), Vector2(18, 2), CORAL, 2.0)
		draw_line(Vector2(18, -4), Vector2(12, 2), CORAL, 2.0)
	else:
		var sick := state == GameState.PLAYING and time_left <= 25.0 and not all_oil_clean()
		var color := Color("#a3b18a") if sick else Color("#ffd166")
		draw_colored_polygon(PackedVector2Array([Vector2(-16, 0), Vector2(-27, -9), Vector2(-27, 9)]), color.darkened(0.18))
		draw_fish_body(Vector2.ZERO, Vector2(19, 10), color)
		draw_circle(Vector2(11, -2), 2.2, Color("#102a43"))
		if sick:
			draw_circle(Vector2(-2, -4), 3.0, Color("#4a5759"))
			draw_line(Vector2(3, 5), Vector2(10, 8), Color("#4a5759"), 3.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_fish_body(center: Vector2, radius: Vector2, color: Color) -> void:
	var points := PackedVector2Array()
	for index in range(24):
		var angle := TAU * float(index) / 24.0
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	draw_colored_polygon(points, color)


func draw_rock(at: Vector2) -> void:
	var source := Rect2(0, 512, 384, 512) if int(at.x) % 2 == 0 else Rect2(384, 512, 384, 512)
	draw_texture_rect_region(OBJECT_SHEET, Rect2(at - Vector2(31, 31), Vector2(62, 62)), source)


func draw_bottle(at: Vector2) -> void:
	var bob := sin(wave_time * 2.2 + at.x) * 4.0
	var variant := int(at.x) % 3
	draw_set_transform(at + Vector2(0, bob), -0.35, Vector2.ONE)
	draw_texture_rect_region(OBJECT_SHEET, Rect2(-21, -21, 42, 42), Rect2(variant * 512, 0, 512, 512))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_kayak() -> void:
	var cell := Vector2(net_state % 2, int(net_state / 2.0)) * 627.0
	draw_set_transform(player, direction.angle() + PI * 0.5, Vector2.ONE)
	var damage_color := Color.WHITE if hit_count == 0 else (Color("#ffd6a5") if hit_count == 1 else Color("#ef8a8a"))
	draw_texture_rect_region(KAYAK_SHEET, Rect2(-48, -48, 96, 96), Rect2(cell, Vector2(627, 627)), damage_color)
	if hit_count >= 1:
		draw_polyline(PackedVector2Array([Vector2(-7, -25), Vector2(2, -13), Vector2(-5, -3)]), Color("#3d1f1f"), 2.0)
	if hit_count >= 2:
		draw_polyline(PackedVector2Array([Vector2(12, 4), Vector2(3, 14), Vector2(10, 26)]), Color("#3d1f1f"), 2.0)
	if hit_count >= MAX_HITS:
		draw_line(Vector2(-31, -31), Vector2(31, 31), CORAL, 4.0)
		draw_line(Vector2(31, -31), Vector2(-31, 31), CORAL, 4.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_hud() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(22, 18, 1108, 64), Color(0.02, 0.12, 0.18, 0.88), true)
	draw_string(font, Vector2(48, 58), "BOTELLAS  %02d / %02d" % [collected_bottles(), BOTTLE_TOTAL], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, CREAM)
	draw_string(font, Vector2(448, 58), "GOLPES  %d / %d" % [hit_count, MAX_HITS], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, CORAL if hit_count >= 2 else CREAM)
	var seconds := maxi(0, ceili(time_left))
	draw_string(font, Vector2(820, 58), "TIEMPO  %02d:%02d" % [int(seconds / 60.0), seconds % 60], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, CREAM)
	if notice_time > 0.0 and state == GameState.PLAYING:
		draw_centered(notice, 112, 20, CREAM)


func draw_menu() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.76), true)
	draw_panel(Rect2(274, 116, 604, 450))
	draw_centered("ECOMISIÓN", 190, 48, GREEN)
	draw_centered("RESCATE EN KAYAK", 232, 28, CREAM)
	draw_centered("Hay 20 botellas: 10 desbloquean cada charco.", 286, 20, Color("#d8f3dc"))
	draw_centered("Acercate al petróleo y mantené ESPACIO para limpiarlo.", 320, 18, Color("#d8f3dc"))
	draw_centered("Cada charco limpio suma 10 segundos.", 354, 18, GREEN)
	draw_centered("Cada golpe resta 5 segundos · 3 golpes terminan la misión.", 386, 17, CORAL)
	draw_centered("MOVIMIENTO: WASD / FLECHAS   ·   RED: ESPACIO", 429, 17, Color("#a9def9"))
	draw_button("COMENZAR MISIÓN")


func draw_end_screen() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.78), true)
	draw_panel(Rect2(274, 132, 604, 420))
	var won := state == GameState.WON
	draw_centered("¡MISIÓN CUMPLIDA!" if won else "MISIÓN INCOMPLETA", 224, 38, GREEN if won else CORAL)
	draw_centered(end_reason, 290, 22, CREAM)
	draw_centered("Botellas recuperadas: %d de %d" % [bottles_collected, BOTTLE_TOTAL], 342, 23, Color("#a9def9"))
	var total_cleanup: float = (oil_cleanups[0] + oil_cleanups[1]) * 0.5
	draw_centered("Petróleo limpiado: %d%%" % int(total_cleanup), 382, 20, GREEN if all_oil_clean() else CORAL)
	draw_centered("Los peces están a salvo." if won else "El río todavía necesita ayuda. Volvé a intentarlo.", 420, 19, Color("#d8f3dc"))
	draw_button("JUGAR DE NUEVO")


func draw_panel(rect: Rect2) -> void:
	draw_rect(rect, Color(0.03, 0.16, 0.22, 0.96), true)
	draw_rect(rect, Color("#52b69a"), false, 3.0)


func draw_button(label: String) -> void:
	var rect := Rect2(442, 492, 268, 58)
	draw_rect(rect, Color("#2a9d8f"), true)
	draw_rect(rect, Color("#b7e4c7"), false, 2.0)
	draw_centered(label, 530, 21, Color.WHITE)


func draw_centered(text: String, y: float, size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, Vector2((SCREEN.x - width) * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
