# Kekoa animation drop-in folder

Put Mixamo clips here and Kekoa uses them automatically the next time you press Play.
No code changes, no AnimationTree edits.

| File name (exact) | Replaces | Suggested Mixamo search |
|---|---|---|
| `Idle.fbx` | standing loop | "Breathing Idle" or "Happy Idle" |
| `Walk.fbx` | walk loop | "Walking" |
| `Run.fbx`  | sprint loop | "Fast Run" or "Running" |
| `Jump.fbx` | take-off (plays once, then the Fall pose holds until landing) | "Jump" |

## Mixamo download settings
1. On mixamo.com, keep **Kekoa** loaded as the character (same one you rigged).
2. Pick the animation. Tick **In Place** if the option is shown.
3. Download with: Format **FBX Binary (.fbx)**, Skin **Without Skin**, Frames per Second **30**, Keyframe Reduction **none**.
4. Rename the file to the exact name in the table and drop it in this folder
   (`player/kekoa/animations/`). Let Godot finish importing, then press Play.

Notes
- Clips from another Mixamo character also work; they are retargeted onto Kekoa when loaded.
- Root motion is removed automatically (Kekoa is moved by the controller), and
  loops are set for Idle/Walk/Run.
- If a new Walk or Run clip has a very different stride, tune `walk_speed` /
  `sprint_speed` on the Player node so the feet don't slide.
- The baked fallback clips live in `player/kekoa/anims/KekoaAnims.tres`
  (rebuild with `tools/build_kekoa_anims.gd`).
