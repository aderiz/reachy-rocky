import SwiftUI
import SceneKit
import GLTFKit2
import RockyKit

/// 3D avatar of Rocky's actual head, loaded from the bundled
/// `Reachy_head.gltf` model and driven by the live robot pose.
///
/// Scene hierarchy:
///   sceneRoot
///     ├ camera (look-at target = poseRig)
///     ├ key light (directional, casts shadow)
///     ├ fill light (ambient)
///     ├ rim light (directional, no shadow)
///     └ poseRig                  ← live yaw/pitch/roll set here
///         └ calibration          ← static Y-up + facing correction
///             └ <loaded Reachy_head + antennas>
///
/// The double-wrap (poseRig + calibration) means setting `eulerAngles`
/// on poseRig animates the head as if it sat on a neck — the calibration
/// step that orients the Onshape export into SceneKit's Y-up world stays
/// untouched and isn't fought by the live-pose mutations.
struct ReachyHead3D: NSViewRepresentable {
    let state: AppServices.RockyState
    let pose: RPYPose?
    let antennas: Antennas?

    /// Static fix-up applied to the Onshape-exported model.
    ///
    /// Composition (applied right-to-left to a vector — the rightmost
    /// rotation hits the model first in its native CAD frame):
    /// 1. `π` around the model's native Z (CAD vertical) — spins the
    ///    head 180° front-to-back so the LCD-plate side ends up where
    ///    the stereo-camera/branding side was. Per user instruction.
    /// 2. `-π/2` around X — Z-up CAD → Y-up SceneKit (head sits
    ///    upright with antennas pointing world `+Y`).
    /// 3. `+π/2` around Y — yaws the upright head so the now-flipped
    ///    LCD side faces world `+Z` (the camera).
    private static let calibrationOrientation: simd_quatf = {
        let zFlip = simd_quatf(angle: .pi,
                                axis: SIMD3<Float>(0, 0, 1))
        let zUpToYUp = simd_quatf(angle: -.pi / 2,
                                   axis: SIMD3<Float>(1, 0, 0))
        let yawToFaceCamera = simd_quatf(angle: .pi / 2,
                                          axis: SIMD3<Float>(0, 1, 0))
        return yawToFaceCamera * zUpToYUp * zFlip
    }()

    /// Target size (in SceneKit units) the model is normalised to after
    /// orientation correction — picked so the head + antennas fit the
    /// camera view with comfortable margin at the default FOV below.
    private static let normalisedHeight: Float = 0.20
    private static let cameraFOV: CGFloat = 32

    /// Multiplier on the geometrically-required camera distance so the
    /// model fits the canvas with breathing room. 1.15 leaves a sliver
    /// of margin so the antennas don't graze the edges, but lets the
    /// head body occupy most of the canvas instead of looking lonely
    /// in the middle. Bump up if antennas start clipping.
    private static let cameraMarginMultiplier: Float = 1.15

    init(
        state: AppServices.RockyState,
        pose: RPYPose?,
        antennas: Antennas?
    ) {
        self.state = state
        self.pose = pose
        self.antennas = antennas
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30

        let scene = Self.loadHeadScene()
        view.scene = scene
        context.coordinator.attach(to: scene)

        // ----- Camera -----
        // Subtle 3/4 view from upper-front-right now that the
        // calibration is correct. Small offsets (0.18 / 0.06) keep the
        // head reading as a head rather than a flat panel without
        // making it ambiguous which face is the front.
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = Self.cameraFOV
        camera.zNear = 0.001
        camera.zFar = 100
        cameraNode.camera = camera
        let half = Double(Self.normalisedHeight) * 0.5
        let halfFovRad = Double(Self.cameraFOV) * .pi / 180.0 * 0.5
        let zDist = Float(half / tan(halfFovRad) * Double(Self.cameraMarginMultiplier))
        cameraNode.position = SCNVector3(zDist * 0.18, zDist * 0.06, zDist)
        if let pose = scene.rootNode.childNode(withName: "poseRig",
                                                recursively: true) {
            let lookAt = SCNLookAtConstraint(target: pose)
            lookAt.isGimbalLockEnabled = true
            cameraNode.constraints = [lookAt]
        }
        scene.rootNode.addChildNode(cameraNode)

        // ----- Lighting -----
        // Key: directional from upper-front-left, casts soft shadows.
        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1100
        keyLight.color = NSColor(white: 1.0, alpha: 1.0)
        keyLight.castsShadow = true
        keyLight.shadowRadius = 6
        keyLight.shadowSampleCount = 16
        keyLight.shadowMode = .deferred
        keyLight.shadowMapSize = CGSize(width: 1024, height: 1024)
        keyLight.shadowColor = NSColor(white: 0, alpha: 0.45)
        key.light = keyLight
        key.position = SCNVector3(0.4, 0.5, 0.3)
        key.eulerAngles = SCNVector3(-0.7, 0.55, 0)
        scene.rootNode.addChildNode(key)

        // Rim: directional from upper-back-right for separation from the
        // dark card background (so the silhouette pops).
        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 700
        rimLight.color = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
        rim.light = rimLight
        rim.eulerAngles = SCNVector3(-0.4, 3.6, 0)
        scene.rootNode.addChildNode(rim)

        // Fill: low ambient so shadows aren't pure black.
        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .ambient
        fillLight.intensity = 220
        fillLight.color = NSColor(white: 1.0, alpha: 1.0)
        fill.light = fillLight
        scene.rootNode.addChildNode(fill)

        // Apply the initial pose so the model isn't mid-T-pose for a beat.
        context.coordinator.apply(state: state, pose: pose, antennas: antennas)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        context.coordinator.apply(state: state, pose: pose, antennas: antennas)
        SCNTransaction.commit()
    }

    // MARK: - Scene loading

    @MainActor private static var cachedSource: SCNScene?

    @MainActor
    private static func loadHeadScene() -> SCNScene {
        if let cached = cachedSource {
            return Self.cloneScene(cached)
        }
        guard let url = Bundle.module.url(forResource: "Reachy_head",
                                          withExtension: "gltf")
        else {
            assertionFailure("Reachy_head.gltf missing from app bundle")
            return SCNScene()
        }
        let loaded: SCNScene
        do {
            let asset = try GLTFAsset(url: url)
            let source = GLTFSCNSceneSource(asset: asset)
            loaded = source.defaultScene ?? SCNScene()
        } catch {
            assertionFailure("GLTFAsset load failed: \(error)")
            loaded = SCNScene()
        }

        // Build the rig hierarchy: poseRig > calibration > loadedRoots.
        // The calibration node holds the static fix-up (Y-up + facing
        // forward) so we never tangle that with the live pose.
        let scene = SCNScene()
        let poseRig = SCNNode()
        poseRig.name = "poseRig"
        let calibration = SCNNode()
        calibration.name = "calibration"

        // Move every top-level loaded node into `calibration`.
        for child in loaded.rootNode.childNodes {
            child.removeFromParentNode()
            calibration.addChildNode(child)
        }

        // Centre + size from the bounding SPHERE (recursive in SceneKit,
        // unlike `boundingBox` which is geometry-LOCAL). This is the
        // only way I've found to be sure the model's actual centre is
        // at world origin no matter how the assembly is structured.
        // Sphere is orientation-independent so it gives the same answer
        // before or after the calibration rotation.
        let (sphereCentre, sphereRadius) = calibration.boundingSphere
        for child in calibration.childNodes {
            child.position = SCNVector3(
                child.position.x - sphereCentre.x,
                child.position.y - sphereCentre.y,
                child.position.z - sphereCentre.z
            )
        }

        // Static orientation correction.
        calibration.simdOrientation = Self.calibrationOrientation

        // Scale the bounding sphere's diameter to `normalisedHeight`.
        let scale: CGFloat = sphereRadius > 0
            ? CGFloat(Self.normalisedHeight) / CGFloat(sphereRadius * 2)
            : 1.0
        poseRig.scale = SCNVector3(scale, scale, scale)

        poseRig.addChildNode(calibration)
        scene.rootNode.addChildNode(poseRig)

        cachedSource = scene
        return Self.cloneScene(scene)
    }

    @MainActor
    private static func cloneScene(_ source: SCNScene) -> SCNScene {
        let copy = SCNScene()
        for child in source.rootNode.childNodes {
            copy.rootNode.addChildNode(child.clone())
        }
        return copy
    }

    // MARK: - Coordinator

    final class Coordinator {
        private weak var poseRig: SCNNode?
        private weak var antennaLeft: SCNNode?
        private weak var antennaRight: SCNNode?
        // CAD-authored rest transforms (full 4x4). gltf-loaded nodes
        // store their pose in the matrix transform, and decomposing to
        // simdOrientation can drop information; using simdTransform
        // preserves the rod's translation + rotation exactly. We
        // compose extras on top so the rod's mount stays put.
        private var restLeftTransform: simd_float4x4 = matrix_identity_float4x4
        private var restRightTransform: simd_float4x4 = matrix_identity_float4x4

        func attach(to scene: SCNScene) {
            poseRig = scene.rootNode.childNode(withName: "poseRig", recursively: true)
            // Bind to the rod sub-nodes (`occurrence of antenna`), not
            // the `antenna <N>` assembly groups. The assemblies have
            // identity transforms but their rod children have non-zero
            // translation matrices in the head's local frame — so
            // rotating an assembly rotates the rod's offset vector
            // around (0,0,0) and the visible rod translates away from
            // its mount. Rotating the rod itself preserves its
            // translation (the mount point) and only changes
            // orientation, so it pivots in place.
            //
            // Both `antenna <1>` and `antenna <2>` contain a child
            // named "occurrence of antenna", so the gltf has two such
            // nodes. `childNode(withName:recursively:)` returns the
            // first match — collect ALL of them and bind in CAD
            // order (antenna <1> is authored first).
            // GLTFKit2 disambiguates duplicate gltf node names by
            // appending `_1` on collision: the left rod stays
            // `occurrence of antenna`, the right one becomes
            // `occurrence of antenna_1`. Search each assembly subtree
            // for either name.
            let assemblyLeft  = scene.rootNode.childNode(
                withName: "antenna <1>", recursively: true)
            let assemblyRight = scene.rootNode.childNode(
                withName: "antenna <2>", recursively: true)
            antennaLeft  = Self.findRod(in: assemblyLeft)
            antennaRight = Self.findRod(in: assemblyRight)
            // Snapshot the CAD-authored rest transforms exactly once.
            if let l = antennaLeft  { restLeftTransform  = l.simdTransform }
            if let r = antennaRight { restRightTransform = r.simdTransform }
        }

        private static func findRod(in assembly: SCNNode?) -> SCNNode? {
            guard let assembly else { return nil }
            return assembly.childNode(withName: "occurrence of antenna",
                                       recursively: true)
                ?? assembly.childNode(withName: "occurrence of antenna_1",
                                       recursively: true)
        }

        func apply(
            state: AppServices.RockyState,
            pose: RPYPose?,
            antennas: Antennas?
        ) {
            // Sleeping → head slumps forward regardless of the live pose
            // (matches the prior 2D avatar's "slumped" affordance).
            let isSleeping = (state == .sleeping)
            let yaw   = pose?.yaw   ?? 0
            let pitch = isSleeping ? 0.55 : (pose?.pitch ?? 0)
            let roll  = pose?.roll  ?? 0

            // poseRig is at calibrated orientation already; setting its
            // eulerAngles applies a head-turn ON TOP of the calibration.
            //   yaw   → Y axis (head-shake left/right)
            //   pitch → X axis (nod forward/back)
            //   roll  → Z axis (head-tilt sideways)
            poseRig?.eulerAngles = SCNVector3(pitch, yaw, roll)

            // Antennas. Two cases:
            //
            // Sleeping: motors are disabled and the daemon's reported
            // antenna positions reflect the last commanded value (0),
            // not the physical slumped position — so following the
            // daemon shows the antennas straight up while the head
            // pitches forward, which looks wrong. Override with a
            // fixed forward droop so the visual matches what the real
            // antennas would do under gravity.
            //
            // Awake: track the daemon's reported angles, dampened
            // (×0.5) and clamped (±60°) so a glitchy reading can't
            // drive the rod into a weird pose. Rotation is around the
            // assembly group's local X — its origin is at the mounting
            // point on the head, which gives the right pivot.
            // Antennas. CAD already places them at the right rest
            // position (slightly outward V, like the real bot awake);
            // we compose extras on top of that rather than overwrite.
            //
            // Awake → daemon's `antennas.left/right` clamped + halved,
            // composed around the hinge (local X) on top of rest, so
            // idle twitches and explicit antenna gestures show in the
            // model. Right side is mirrored (negate) the same way the
            // original eulerAngles code did.
            // Sleep → 180° around the same hinge axis, putting the rod
            // pointing down (motors-off pose on the real bot).
            if isSleeping {
                applySleepFold(antennaLeft,  rest: restLeftTransform)
                applySleepFold(antennaRight, rest: restRightTransform)
            } else {
                let limit = Double.pi / 3
                let scale = 0.5
                let aL = max(-limit, min(limit, Double(antennas?.left ?? 0))) * scale
                let aR = max(-limit, min(limit, Double(antennas?.right ?? 0))) * scale
                applyAwakeTwitch(antennaLeft,  rest: restLeftTransform,  angle: Float(aL))
                applyAwakeTwitch(antennaRight, rest: restRightTransform, angle: Float(-aR))
            }
        }

        /// Compose a hinge-axis (local X) rotation on top of the CAD
        /// rest transform. Post-multiplying by the rotation matrix
        /// rotates in the rod's own local frame, leaving translation
        /// alone — the rod pivots at its CAD-authored mount.
        private func applyAwakeTwitch(_ node: SCNNode?,
                                       rest: simd_float4x4,
                                       angle: Float) {
            guard let node else { return }
            let twitch = simd_float4x4(simd_quatf(angle: angle,
                                                   axis: SIMD3<Float>(1, 0, 0)))
            node.simdTransform = rest * twitch
        }

        /// Half-turn the antenna around its own hinge axis (local X)
        /// from rest. Post-multiply preserves the rod's translation
        /// and only rotates, so the rod swings 180° at the mount —
        /// matching how the real bot's antennas drape down when
        /// motors disable.
        private func applySleepFold(_ node: SCNNode?, rest: simd_float4x4) {
            guard let node else { return }
            let flip = simd_float4x4(simd_quatf(angle: .pi,
                                                 axis: SIMD3<Float>(1, 0, 0)))
            node.simdTransform = rest * flip
        }
    }
}
