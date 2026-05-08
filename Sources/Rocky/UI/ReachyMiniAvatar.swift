import SwiftUI
import SceneKit
import RockyKit

/// Live SwiftUI wrapper around `ReachyMini` (URDF + STL loader). Drives
/// the URDF the same way the Pollen Tauri app does: by feeding the
/// daemon's 7-element `head_joints` (index 0 = body_yaw, 1..6 =
/// stewart motor angles) plus 2 antenna angles into the bundled WASM
/// forward kinematics, then applying the 21 returned passive-joint
/// angles alongside the motors. The head pose follows naturally from
/// the kinematic chain — no `setHeadEuler` shortcut.
///
/// Inputs:
///   - `state`         — drives the sleep override (slump + antenna fold)
///   - `headJoints`    — 7 floats from the daemon: [body_yaw, stewart_1..6]
///   - `passiveJoints` — 21 passive joint angles if the daemon provides
///                       them; otherwise the IK is run locally via WASM
///   - `antennas`      — 2 antenna angles (radians)
///   - `bodyYaw`       — fallback when `headJoints` is missing
///   - `pose`          — diagnostic only; the chain drives the head pose
///
/// The daemon only populates `head_joints` / `passive_joints` when
/// the request includes the matching `with_*=true` flags — see
/// `RobotLinkClient.fullStateQuery`. Without those flags the avatar
/// falls back to URDF rest (the "shipping" pose).
struct ReachyMiniAvatar: View {
    let state: AppServices.RockyState
    let pose: RPYPose?
    let antennas: Antennas?
    let bodyYaw: Double?
    let headJoints: [Double]?
    let passiveJoints: [Double]?

    init(
        state: AppServices.RockyState,
        pose: RPYPose?,
        antennas: Antennas?,
        bodyYaw: Double? = nil,
        headJoints: [Double]? = nil,
        passiveJoints: [Double]? = nil
    ) {
        self.state = state
        self.pose = pose
        self.antennas = antennas
        self.bodyYaw = bodyYaw
        self.headJoints = headJoints
        self.passiveJoints = passiveJoints
    }

    var body: some View {
        // The avatar itself is transparent — the SCN view has a clear
        // background. Each callsite provides its own backdrop so the
        // 3D model can sit seamlessly in the surrounding layout
        // (cockpit stage uses a full-column gradient; the inspector
        // tab uses a rounded-card material). Earlier this struct
        // owned its own gradient, which made the bot read as a
        // framed picture-in-picture against whatever sat behind it.
        AvatarSceneView(
            state: state, pose: pose, antennas: antennas,
            bodyYaw: bodyYaw, headJoints: headJoints,
            passiveJoints: passiveJoints
        )
    }

    /// Shared gradient used by callsites that want the cockpit's
    /// "presence" backdrop behind the avatar — slate at the crown so
    /// antenna silhouettes read against a lighter region, fading to
    /// near-black at the base. Exposed here so PortraitView and any
    /// future hero surface use the same stops.
    static var backdrop: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.20, green: 0.23, blue: 0.28),
                Color(red: 0.10, green: 0.12, blue: 0.15),
                Color(red: 0.04, green: 0.05, blue: 0.07)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// SceneKit content for `ReachyMiniAvatar`. Kept private so callers
/// always go through the gradient-backed wrapper above; embedding the
/// SCNView raw skips the backdrop and the antennas disappear.
private struct AvatarSceneView: NSViewRepresentable {
    let state: AppServices.RockyState
    let pose: RPYPose?
    let antennas: Antennas?
    let bodyYaw: Double?
    let headJoints: [Double]?
    let passiveJoints: [Double]?

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

        // Wrap the URDF root in a "presentation" node so we can apply
        // a yaw without fighting the URDF's own Z-up → Y-up correction
        // (which sits on `robot.rootNode.simdOrientation`). The URDF's
        // face direction (camera mount) is on its -Y axis, which after
        // the loader's Z→Y rotation maps to world +Z by way of a -90°
        // yaw — verified empirically: -π/2 puts the eyes toward the
        // camera, +π/2 turns the bot 180° and shows its back.
        let presentation = SCNNode()
        presentation.name = "presentation"
        presentation.simdOrientation = simd_quatf(
            angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)
        )
        if let robot = Self.loadRobot() {
            presentation.addChildNode(robot.rootNode)
            context.coordinator.robot = robot
        }
        scene.rootNode.addChildNode(presentation)

        // Camera framed on the full bot.
        let lookAtTarget = SCNNode()
        lookAtTarget.position = SCNVector3(0, 0.20, 0)
        scene.rootNode.addChildNode(lookAtTarget)

        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        camera.fieldOfView = 32
        camera.zNear = 0.01
        camera.zFar = 5
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.22, 0.95)
        let lookAt = SCNLookAtConstraint(target: lookAtTarget)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        // Lighting — 4-source rig tuned for the dark-gradient backdrop.
        // The two antennas are matte black and tall: without a strong
        // rim and a top kicker they vanish into the body. The key is
        // intentionally cooler than typical so the warm rim reads as
        // an edge, not as colour drift on the white shell.
        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1050
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

        // Warm rim from behind-right — silhouettes the antenna trailing
        // edges and the back of the head plate against the gradient.
        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 1300
        rimLight.color = NSColor(calibratedRed: 1.0, green: 0.92,
                                  blue: 0.78, alpha: 1.0)
        rim.light = rimLight
        rim.eulerAngles = SCNVector3(-0.3, 3.6, 0)
        scene.rootNode.addChildNode(rim)

        // Top kicker — cool directional pointing straight down, just
        // bright enough to put highlights on the antenna tips and the
        // upper crown of the head plate. Without this the antennas
        // remain a flat black streak.
        let top = SCNNode()
        let topLight = SCNLight()
        topLight.type = .directional
        topLight.intensity = 500
        topLight.color = NSColor(calibratedRed: 0.85, green: 0.92,
                                  blue: 1.0, alpha: 1.0)
        top.light = topLight
        top.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(top)

        // Ambient — bumped from the previous 220 because the gradient
        // backdrop is darker than the original `.regularMaterial`
        // surface and the body's lower half was reading near-black.
        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .ambient
        fillLight.intensity = 340
        fillLight.color = NSColor(white: 1.0, alpha: 1.0)
        fill.light = fillLight
        scene.rootNode.addChildNode(fill)

        context.coordinator.apply(state: state, pose: pose,
                                   antennas: antennas, bodyYaw: bodyYaw,
                                   headJoints: headJoints,
                                   passiveJoints: passiveJoints)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.18
        context.coordinator.apply(state: state, pose: pose,
                                   antennas: antennas, bodyYaw: bodyYaw,
                                   headJoints: headJoints,
                                   passiveJoints: passiveJoints)
        SCNTransaction.commit()
    }

    // MARK: - One-shot loaders (cached)

    @MainActor private static var cachedRobot: ReachyMini?
    @MainActor private static var cachedIK: StewartIK?

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

    @MainActor
    fileprivate static func loadIK() -> StewartIK? {
        if let cached = cachedIK { return cached }
        guard let url = Bundle.module.url(
            forResource: "reachy_mini_kinematics",
            withExtension: "wasm",
            subdirectory: "ReachyMini"
        ) else {
            assertionFailure("reachy_mini_kinematics.wasm missing from app bundle")
            return nil
        }
        do {
            let ik = try StewartIK(wasmURL: url)
            cachedIK = ik
            return ik
        } catch {
            assertionFailure("StewartIK init failed: \(error)")
            return nil
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        weak var robot: ReachyMini?

        func apply(
            state: AppServices.RockyState,
            pose: RPYPose?,
            antennas: Antennas?,
            bodyYaw: Double?,
            headJoints: [Double]?,
            passiveJoints: [Double]?
        ) {
            guard let robot else { return }
            _ = state

            robot.setStewartLinkageHidden(false)

            // Antennas — daemon's antennas_position[0] is the right
            // antenna and [1] is the left. Per Pollen's URDFLoader
            // mapping both are negated so positive daemon values
            // correspond to "antenna leans forward" in either frame.
            let rightDaemon = antennas?.right ?? 0
            let leftDaemon  = antennas?.left  ?? 0
            robot.setAntennas(
                left:  Float(-leftDaemon),
                right: Float(-rightDaemon)
            )

            // The daemon's 7-float `head_joints`: index 0 = body_yaw,
            // 1..6 = stewart motor angles. Both directly drive the
            // URDF chain (compose-with-rest in setBodyYaw /
            // setStewartActuators).
            if let hj = headJoints, hj.count == 7 {
                robot.setBodyYaw(Float(hj[0]))
                robot.setStewartActuators(hj[1...6].map { Float($0) })

                // Passive joints close the Stewart linkage. Prefer
                // the daemon's pre-computed values when present;
                // otherwise run the bundled WASM forward kinematics
                // locally. The WASM signature is
                // `(head_joints[7], head_pose_matrix[16]) → passive[21]`.
                let passive: [Double]?
                if let provided = passiveJoints, provided.count == 21 {
                    passive = provided
                } else if let ik = AvatarSceneView.loadIK() {
                    let m = Self.headPoseMatrix(pose ?? .zero)
                    passive = ik.calculatePassiveJoints(
                        headJoints: hj, headPoseMatrix: m
                    )
                } else {
                    passive = nil
                }
                if let passive {
                    for i in 0..<7 {
                        let base = i * 3
                        robot.setJoint("passive_\(i+1)_x",
                                        angle: Float(passive[base + 0]))
                        robot.setJoint("passive_\(i+1)_y",
                                        angle: Float(passive[base + 1]))
                        robot.setJoint("passive_\(i+1)_z",
                                        angle: Float(passive[base + 2]))
                    }
                }
            } else {
                robot.setBodyYaw(Float(bodyYaw ?? 0))
            }
        }

        /// Build the 4×4 row-major homogeneous transform that the
        /// bundled WASM expects as its second `calculate_passive_joints`
        /// argument. `R = Rz(yaw) · Ry(pitch) · Rx(roll)` (intrinsic
        /// XYZ Tait-Bryan, matching the daemon's RPY convention),
        /// translation goes in the rightmost column.
        private static func headPoseMatrix(_ p: RPYPose) -> [Double] {
            let cr = cos(p.roll),  sr = sin(p.roll)
            let cp = cos(p.pitch), sp = sin(p.pitch)
            let cy = cos(p.yaw),   sy = sin(p.yaw)
            let m00 = cy*cp,        m01 = cy*sp*sr - sy*cr, m02 = cy*sp*cr + sy*sr
            let m10 = sy*cp,        m11 = sy*sp*sr + cy*cr, m12 = sy*sp*cr - cy*sr
            let m20 = -sp,          m21 = cp*sr,            m22 = cp*cr
            return [
                m00, m01, m02, p.x,
                m10, m11, m12, p.y,
                m20, m21, m22, p.z,
                0,   0,   0,   1
            ]
        }
    }
}
