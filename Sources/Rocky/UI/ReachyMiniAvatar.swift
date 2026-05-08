import SwiftUI
import SceneKit
import RockyKit

/// Live SwiftUI wrapper around `ReachyMini` (URDF + STL loader). Drives
/// the URDF the same way the Pollen Tauri app does: by feeding the 6
/// Stewart motor angles + 2 antenna angles into the bundled WASM
/// kinematics, then applying the 18 returned passive-joint angles
/// alongside the motor angles. The head pose follows naturally from
/// the kinematic chain — no `setHeadEuler` shortcut.
///
/// Inputs:
///   - `state`         — drives the sleep override (slump + antenna fold)
///   - `headJoints`    — 6 stewart motor angles (radians)
///   - `passiveJoints` — 18 passive joint angles (radians) if the daemon
///                       provides them; otherwise the IK is run locally
///   - `antennas`      — 2 antenna angles (radians)
///   - `bodyYaw`       — single body rotation around the foot
///   - `pose`          — fallback head pose for the legacy "no motor
///                       angles" path (used only when both `headJoints`
///                       and the IK are unavailable)
///
/// When motor angles are available the Stewart linkage rods are visible
/// and animate correctly. When they're not, the linkage is hidden and
/// the head is driven directly via `setHeadEuler` — honest stub for
/// when the daemon hasn't started reporting joint state yet.
struct ReachyMiniAvatar: NSViewRepresentable {
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
        // (which sits on `robot.rootNode.simdOrientation`). The URDF
        // imports facing away from the camera; a 180° yaw around the
        // world Y axis turns the bot to face us.
        let presentation = SCNNode()
        presentation.name = "presentation"
        presentation.simdOrientation = simd_quatf(
            angle: .pi, axis: SIMD3<Float>(0, 1, 0)
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

        // Lighting — soft 3-point. Warm key from upper-front-left, cool
        // rim from upper-back-right, low ambient fill so shadows don't
        // go pure black.
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

            let isSleeping = (state == .sleeping)

            // Antennas — sleep folds them down regardless of live
            // values; awake uses the daemon's reported angles.
            let antennaPair: (left: Float, right: Float)
            if isSleeping {
                let fold = Float.pi
                antennaPair = (left: fold, right: fold)
            } else {
                antennaPair = (
                    left: Float(antennas?.left ?? 0),
                    right: Float(antennas?.right ?? 0)
                )
            }

            // Body yaw — single rotation around the foot, always live.
            robot.setBodyYaw(Float(bodyYaw ?? 0))

            // Stewart platform — preferred path. When motor angles are
            // available we drive the URDF as the Pollen app does:
            //   1. setStewartActuators(headJoints)
            //   2. compute passive joints (use daemon's if present;
            //      fall back to local WASM IK; fall back to zeros)
            //   3. setJoint(passive_N_x|y|z, ...) for each
            // Sleep state ignores motor angles and uses the head-Euler
            // override so the bot looks visibly slumped — the rods
            // would visually disconnect, so we hide the linkage too.
            if isSleeping {
                robot.setStewartLinkageHidden(true)
                robot.setHeadEuler(roll: 0.05, pitch: 0.55, yaw: 0)
                robot.setAntennas(left: antennaPair.left,
                                   right: antennaPair.right)
                return
            }

            if let motors = headJoints, motors.count == 6 {
                robot.setStewartLinkageHidden(false)
                robot.setStewartActuators(motors.map { Float($0) })

                // Passive joints — daemon-provided or computed locally.
                let passive: [Double]?
                if let provided = passiveJoints, provided.count == 18 {
                    passive = provided
                } else if let ik = ReachyMiniAvatar.loadIK() {
                    passive = ik.calculatePassiveJoints(
                        headJoints: motors,
                        antennas: [Double(antennaPair.left),
                                    Double(antennaPair.right)]
                    )
                } else {
                    passive = nil
                }
                if let passive {
                    for i in 0..<6 {
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
                // Fallback: no motor angles from the daemon. Hide the
                // linkage (it can't follow the head pose without IK)
                // and animate the head directly. Honest stub until the
                // daemon reports head_joints.
                robot.setStewartLinkageHidden(true)
                let p = pose ?? RPYPose(roll: 0, pitch: 0, yaw: 0)
                robot.setHeadEuler(roll: Float(p.roll),
                                    pitch: Float(p.pitch),
                                    yaw: Float(p.yaw))
            }

            robot.setAntennas(left: antennaPair.left,
                               right: antennaPair.right)
        }
    }
}
