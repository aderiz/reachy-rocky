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

        func attach(to scene: SCNScene) {
            poseRig = scene.rootNode.childNode(withName: "poseRig", recursively: true)
            antennaLeft = scene.rootNode.childNode(
                withName: "antenna <1>", recursively: true
            )
            antennaRight = scene.rootNode.childNode(
                withName: "antenna <2>", recursively: true
            )
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

            // Antennas. Joint angles come in radians; 0.6 dampens the
            // visible swing so it feels more like an antenna wobble than
            // a hinge slam. Mirror the right side so they tilt outward
            // symmetrically.
            let aL = Double(antennas?.left ?? 0) * 0.6
            let aR = Double(antennas?.right ?? 0) * 0.6
            antennaLeft?.eulerAngles  = SCNVector3(aL,  0, 0)
            antennaRight?.eulerAngles = SCNVector3(-aR, 0, 0)
        }
    }
}
