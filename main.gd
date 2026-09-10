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
const GAME_TIME := 150.0
const PLAYER_SPEED := 255.0
const OIL_RADIUS := 72.0
const OIL_CLEAN_RATE := 14.0
const FISH_CAGE := Rect2(938, 178, 184, 276)
const OIL_START := Vector2(650, 350)
const OIL_TARGET := Vector2(890, 330)
const WATER := Color("#168aad")
const DEEP_WATER := Color("#0b6e91")
const CREAM := Color("#fff4d6")
const GREEN := Color("#7ae582")
const CORAL := Color("#ff6b6b")

var state := GameState.MENU
var player := Vector2(105, 330)
var direction := Vector2.RIGHT
var bottles: Array[Vector2] = []
var time_left := GAME_TIME
var oil_cleanup := 0.0
var oil_center := OIL_START
var fish_alive := true
var wave_time := 0.0
var hit_cooldown := 0.0
var flash := 0.0
var notice := ""
var notice_time := 0.0
var end_reason := ""
var net_state := NetState.IDLE
var net_timer := 0.0
var pending_bottle := -1
var oil_clean_notified := false

var bottle_spawns := [
	Vector2(170, 155), Vector2(330, 125), Vector2(505, 180),
	Vector2(720, 135), Vector2(850, 165), Vector2(225, 315),
	Vector2(435, 350), Vector2(300, 505), Vector2(555, 525),
	Vector2(825, 505)
]

var rocks := [
	Vector2(260, 220), Vector2(405, 445), Vector2(585, 235),
	Vector2(750, 405), Vector2(930, 245), Vector2(1030, 500)
]

func _ready() -> void:
	get_window().title = "EcoMisión: Rescate en Kayak"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	bottles.assign(bottle_spawns)
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
	bottles = [Vector2(1000, 100)]
	cast_net()
	resolve_net()
	assert(net_state == NetState.MISS and bottles.size() == 1)
	start_game()
	bottles = [player + direction * 92.0]
	cast_net()
	resolve_net()
	oil_cleanup = 100.0
	update_game(0.01)
	assert(state == GameState.WON)
	start_game()
	time_left = 0.0
	update_game(0.01)
	assert(state == GameState.LOST)
	print("SELF_TEST_OK: victoria y derrota verificadas")
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
	oil_center = OIL_START.lerp(OIL_TARGET, clampf(elapsed / GAME_TIME, 0.0, 1.0))
	hit_cooldown = maxf(0.0, hit_cooldown - delta)

	var movement := Vector2(
		float(Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)),
		float(Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)) - float(Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP))
	).normalized()

	if movement != Vector2.ZERO:
		direction = movement
		var speed := PLAYER_SPEED * (0.58 if is_touching_oil() else 1.0)
		var previous := player
		player += movement * speed * delta
		player.x = clampf(player.x, 38.0, SCREEN.x - 38.0)
		player.y = clampf(player.y, 100.0, SCREEN.y - 38.0)
		for rock in rocks:
			if player.distance_to(rock) < 38.0:
				player = previous
				hit_rock()
				break

	if is_touching_oil() and Input.is_key_pressed(KEY_SPACE):
		clean_oil(delta)

	if bottles.is_empty() and oil_cleanup >= 100.0:
		finish_game(true, "¡El río quedó libre de residuos!")
	elif time_left <= 0.0:
		fish_alive = oil_cleanup >= 100.0
		var reason := "Se acabó el tiempo: el petróleo alcanzó a los peces." if not fish_alive else "Se acabó el tiempo y quedaron botellas en el río."
		finish_game(false, reason)


func is_touching_oil() -> bool:
	return oil_cleanup < 100.0 and player.distance_to(oil_center) < OIL_RADIUS + 46.0


func clean_oil(delta: float) -> void:
	var previous := oil_cleanup
	oil_cleanup = minf(100.0, oil_cleanup + OIL_CLEAN_RATE * delta)
	notice = "Limpiando petróleo... %d%%" % int(oil_cleanup)
	notice_time = 0.2
	if previous < 100.0 and oil_cleanup >= 100.0 and not oil_clean_notified:
		oil_clean_notified = true
		notice = "¡Petróleo retirado al 100%!"
		notice_time = 2.0
		play_sound(COLLECT_SOUND, -1.0, 0.82)


func hit_rock() -> void:
	if hit_cooldown > 0.0:
		return
	hit_cooldown = 0.7
	time_left = maxf(0.0, time_left - 3.0)
	flash = 0.35
	notice = "¡Cuidado! La roca costó 3 segundos"
	notice_time = 1.5
	play_sound(WATER_IMPACT, -5.0, 0.72)


func cast_net() -> void:
	if net_state != NetState.IDLE:
		return
	net_state = NetState.CAST
	net_timer = 0.18
	play_sound(WATER_IMPACT, -11.0, 1.32)
	pending_bottle = -1
	var target := player + direction * 92.0
	var best_distance := 66.0
	for index in bottles.size():
		var distance := bottles[index].distance_to(target)
		if distance < best_distance:
			best_distance = distance
			pending_bottle = index


func resolve_net() -> void:
	if pending_bottle >= 0 and pending_bottle < bottles.size():
		bottles.remove_at(pending_bottle)
		net_state = NetState.CATCH
		play_sound(COLLECT_SOUND, -2.0, 1.08)
		flash = 0.16
		notice = "+1 botella recuperada"
	else:
		net_state = NetState.MISS
		notice = "La red no atrapó nada"
		play_sound(FAILURE_SOUND, -9.0, 1.25)
	net_timer = 0.42
	notice_time = 1.1
	pending_bottle = -1


func start_game() -> void:
	state = GameState.PLAYING
	player = Vector2(105, 330)
	direction = Vector2.RIGHT
	bottles.assign(bottle_spawns)
	time_left = GAME_TIME
	oil_cleanup = 0.0
	oil_center = OIL_START
	fish_alive = true
	oil_clean_notified = false
	hit_cooldown = 0.0
	flash = 0.0
	notice = "Recolectá 10 botellas y limpiá el petróleo antes de que llegue a los peces"
	notice_time = 3.2
	end_reason = ""
	net_state = NetState.IDLE
	net_timer = 0.0
	pending_bottle = -1
	play_sound(COLLECT_SOUND, -8.0, 0.9)


func finish_game(won: bool, reason: String) -> void:
	state = GameState.WON if won else GameState.LOST
	end_reason = reason
	play_sound(VICTORY_SOUND if won else FAILURE_SOUND, -1.5)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE and state == GameState.PLAYING:
			if not is_touching_oil():
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
	draw_oil()
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


func draw_oil() -> void:
	if oil_cleanup >= 100.0:
		return
	var remaining := 1.0 - oil_cleanup / 100.0
	var radius := OIL_RADIUS * lerpf(0.38, 1.0, sqrt(remaining))
	draw_circle(oil_center, radius * 0.82, Color(0.025, 0.025, 0.035, 0.72))
	var size := radius * 2.0
	draw_texture_rect_region(OBJECT_SHEET, Rect2(oil_center - Vector2.ONE * size * 0.5, Vector2.ONE * size), Rect2(768, 512, 480, 512))
	draw_arc(oil_center, radius, 0.0, TAU, 64, Color(0.55, 0.15, 0.72, 0.55), 3.0)
	var font := ThemeDB.fallback_font
	var label := "LIMPIEZA %d%%" % int(oil_cleanup)
	var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	draw_string(font, oil_center + Vector2(-label_width * 0.5, -radius - 10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, CREAM)
	if is_touching_oil():
		draw_centered("MANTENÉ ESPACIO PARA LIMPIAR", 604, 18, CREAM)
		draw_rect(Rect2(376, 615, 400, 10), Color("#17324d"), true)
		draw_rect(Rect2(376, 615, 400.0 * oil_cleanup / 100.0, 10), GREEN, true)


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
	var color := Color("#ffd166") if fish_alive else Color("#6c757d")
	var facing := 1.0 if faces_right else -1.0
	draw_set_transform(at, 0.0, Vector2(facing, 1.0))
	draw_colored_polygon(PackedVector2Array([Vector2(-20, 0), Vector2(-34, -12), Vector2(-34, 12)]), color.darkened(0.18))
	draw_fish_body(Vector2.ZERO, Vector2(24, 13), color)
	draw_circle(Vector2(13, -3), 2.5, Color("#102a43"))
	if not fish_alive:
		draw_line(Vector2(9, -7), Vector2(17, 1), CORAL, 2.0)
		draw_line(Vector2(17, -7), Vector2(9, 1), CORAL, 2.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_fish_body(center: Vector2, radius: Vector2, color: Color) -> void:
	var points := PackedVector2Array()
	for index in range(24):
		var angle := TAU * float(index) / 24.0
		points.append(center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y))
	draw_colored_polygon(points, color)


func draw_rock(at: Vector2) -> void:
	var source := Rect2(0, 512, 384, 512) if int(at.x) % 2 == 0 else Rect2(384, 512, 384, 512)
	draw_texture_rect_region(OBJECT_SHEET, Rect2(at - Vector2(43, 43), Vector2(86, 86)), source)


func draw_bottle(at: Vector2) -> void:
	var bob := sin(wave_time * 2.2 + at.x) * 4.0
	var variant := int(at.x) % 3
	draw_set_transform(at + Vector2(0, bob), -0.35, Vector2.ONE)
	draw_texture_rect_region(OBJECT_SHEET, Rect2(-30, -30, 60, 60), Rect2(variant * 512, 0, 512, 512))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_kayak() -> void:
	var cell := Vector2(net_state % 2, int(net_state / 2.0)) * 627.0
	draw_set_transform(player, direction.angle() + PI * 0.5, Vector2.ONE)
	draw_texture_rect_region(KAYAK_SHEET, Rect2(-66, -66, 132, 132), Rect2(cell, Vector2(627, 627)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func draw_hud() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(22, 18, 1108, 64), Color(0.02, 0.12, 0.18, 0.88), true)
	draw_string(font, Vector2(48, 58), "BOTELLAS  %02d / %02d" % [bottle_spawns.size() - bottles.size(), bottle_spawns.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 24, CREAM)
	var seconds := maxi(0, ceili(time_left))
	draw_string(font, Vector2(790, 58), "TIEMPO  %02d:%02d" % [int(seconds / 60.0), seconds % 60], HORIZONTAL_ALIGNMENT_LEFT, -1, 24, CREAM)
	if notice_time > 0.0 and state == GameState.PLAYING:
		draw_centered(notice, 112, 20, CREAM)


func draw_menu() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.76), true)
	draw_panel(Rect2(274, 116, 604, 450))
	draw_centered("ECOMISIÓN", 190, 48, GREEN)
	draw_centered("RESCATE EN KAYAK", 232, 28, CREAM)
	draw_centered("El petróleo avanza hacia la jaula de los peces.", 294, 21, Color("#d8f3dc"))
	draw_centered("Recuperá las 10 botellas y limpiá la mancha al 100%", 328, 21, Color("#d8f3dc"))
	draw_centered("antes de que se termine el tiempo.", 362, 21, Color("#d8f3dc"))
	draw_centered("MOVIMIENTO: WASD / FLECHAS   ·   RED: ESPACIO", 416, 17, Color("#a9def9"))
	draw_centered("SOBRE EL PETRÓLEO: MANTENÉ ESPACIO", 445, 17, GREEN)
	draw_button("COMENZAR MISIÓN")


func draw_end_screen() -> void:
	draw_rect(Rect2(0, 0, SCREEN.x, SCREEN.y), Color(0.015, 0.07, 0.1, 0.78), true)
	draw_panel(Rect2(274, 132, 604, 420))
	var won := state == GameState.WON
	draw_centered("¡MISIÓN CUMPLIDA!" if won else "MISIÓN INCOMPLETA", 224, 38, GREEN if won else CORAL)
	draw_centered(end_reason, 290, 22, CREAM)
	var recovered := bottle_spawns.size() - bottles.size()
	draw_centered("Botellas recuperadas: %d de %d" % [recovered, bottle_spawns.size()], 342, 23, Color("#a9def9"))
	draw_centered("Petróleo limpiado: %d%%" % int(oil_cleanup), 382, 20, GREEN if oil_cleanup >= 100.0 else CORAL)
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
