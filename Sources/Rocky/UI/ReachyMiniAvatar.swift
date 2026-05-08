import SwiftUI
import SceneKit
import RockyKit

/// Live SwiftUI wrapper around `ReachyMini` (URDF + STL loader). Drop-in
/// replacement for the older `ReachyHead3D`: same call signature
/// (rockyState + headPose + antennas), same camera framing, but the
/// scene is now the full robot model from the Pollen bundle.
///
/// Per the bundle's README: setting `setHeadEuler` directly bypasses
/// the Stewart-platform IK, so the leg rods between the body and the
/// upper plate visually disconnect during head motion. We crop the
/// camera tightly to the head/antennas, hiding the legs entirely.
/// The cockpit / inspector preview never sees the broken linkage.
///
/// Sleep behaviour preserved from the previous avatar — when
/// `state == .sleeping` we override the antennas to fold down (π
/// around their hinge axis), regardless of the live `antennas` value.
struct ReachyMiniAvatar: NSViewRepresentable {
    let state: AppServices.RockyState
    let pose: RPYPose?
    let antennas: Antennas?
    let bodyYaw: Double?

    init(
        state: AppServices.RockyState,
        pose: RPYPose?,
        antennas: Antennas?,
        bodyYaw: Double? = nil
    ) {
        self.state = state
        self.pose = pose
        self.antennas = antennas
        self.bodyYaw = bodyYaw
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30

        let scene = SCNScene()
        view.scene = scene

        if let robot = Self.loadRobot() {
            // Place the loaded robot under our own poseRig so we can
            // tweak orientation without fighting the URDF Z-up → Y-up
            // rotation the loader already applied.
            scene.rootNode.addChildNode(robot.rootNode)
            context.coordinator.robot = robot
        }

        // Camera, framed on the head — close in so the (mis-IK'd)
        // Stewart legs and the body fall outside the viewport.
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.zNear = 0.01
        camera.zFar = 5
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.18, 0.30, 0.55)
        cameraNode.eulerAngles = SCNVector3(-0.05, 0.32, 0)
        scene.rootNode.addChildNode(cameraNode)

        // Lighting — soft 3-point. Same intent as the previous avatar:
        // a warm key from upper-front-left, a cool rim from upper-back-
        // right, and a low ambient fill so shadows don't go pure black.
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
        key.eulerAngles = SCNVector3(-0.7, 0.55, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 700
        rimLight.color = NSColor(calibratedRed: 0.7, green: 0.85,
                                  blue: 1.0, alpha: 1.0)
        rim.light = rimLight
        rim.eulerAngles = SCNVector3(-0.4, 3.6, 0)
        scene.rootNode.addChildNode(rim)

        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .ambient
        fillLight.intensity = 220
        fillLight.color = NSColor(white: 1.0, alpha: 1.0)
        fill.light = fillLight
        scene.rootNode.addChildNode(fill)

        context.coordinator.apply(state: state, pose: pose,
                                   antennas: antennas, bodyYaw: bodyYaw)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        context.coordinator.apply(state: state, pose: pose,
                                   antennas: antennas, bodyYaw: bodyYaw)
        SCNTransaction.commit()
    }

    // MARK: - One-shot loader (cached)

    @MainActor private static var cachedRobot: ReachyMini?

    @MainActor
    private static func loadRobot() -> ReachyMini? {
        if let cached = cachedRobot { return cached }
        guard let url = Bundle.module.url(forResource: "reachy_mini",
                                          withExtension: "urdf",
                                          subdirectory: "ReachyMini")
        else {
            assertionFailure("reachy_mini.urdf missing from app bundle")
            return nil
        }
        let meshDir = url.deletingLastPathComponent()
            .appendingPathComponent("meshes")
        do {
            let robot = try ReachyMini(urdfURL: url, meshDirectoryURL: meshDir)
            cachedRobot = robot
            return robot
        } catch {
            assertionFailure("ReachyMini load failed: \(error)")
            return nil
        }
    }

    // MARK: - Coordinator

    final class Coordinator {
        weak var robot: ReachyMini?
        private var lastSleeping: Bool?

        func apply(
            state: AppServices.RockyState,
            pose: RPYPose?,
            antennas: Antennas?,
            bodyYaw: Double?
        ) {
            guard let robot else { return }

            let isSleeping = (state == .sleeping)

            // Head pose — drive from live `pose` when awake, slump
            // gently forward when asleep to match the menu-bar pose.
            let headPose = pose ?? RPYPose(roll: 0, pitch: 0, yaw: 0)
            let pitch = isSleeping ? 0.55 : Float(headPose.pitch)
            let roll  = isSleeping ? 0.05 : Float(headPose.roll)
            let yaw   = Float(headPose.yaw)
            robot.setHeadEuler(roll: roll, pitch: pitch, yaw: yaw)

            // Antennas. Awake → live values; sleeping → folded down at
            // the joint hinge so they drape across the head shell, the
            // same shape as the old GLTF avatar achieved.
            if isSleeping {
                let fold = Float.pi
                robot.setAntennas(left: fold, right: fold)
            } else {
                let live = antennas
                let l = Float(live?.left ?? 0)
                let r = Float(live?.right ?? 0)
                robot.setAntennas(left: l, right: r)
            }

            // Body yaw — single floor rotation around the foot.
            robot.setBodyYaw(Float(bodyYaw ?? 0))

            lastSleeping = isSleeping
        }
    }
}
