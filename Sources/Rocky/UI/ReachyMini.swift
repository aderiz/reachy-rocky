import Foundation
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

// Loads the Reachy Mini robot from its URDF + STL meshes into a SceneKit hierarchy
// and exposes a motion API. Meant to be embedded in iOS/macOS Swift apps.
//
// Bundle layout this file expects:
//
//   reachy_mini.urdf
//   meshes/
//     body_foot_3dprint.stl
//     body_down_3dprint.stl
//     ...
//
// Drop the `meshes/` directory + `reachy_mini.urdf` into your app bundle, then:
//
//   let robot = try ReachyMini(bundleURL: Bundle.main.url(forResource: "reachy_mini", withExtension: "urdf")!)
//   sceneView.scene?.rootNode.addChildNode(robot.rootNode)
//   robot.setHeadEuler(roll: 0, pitch: 0.2, yaw: 0)
//   robot.setAntennas(left: 0.3, right: -0.3)
//   robot.setBodyYaw(0.5)
//
// All angles are in radians. Translations are in metres.

public final class ReachyMini {

    // The root SCNNode you add to your scene.
    public let rootNode = SCNNode()

    // Lookup tables built from the URDF.
    private(set) var links:  [String: Link] = [:]
    private(set) var joints: [String: Joint] = [:]

    // Convenience handles to the most-used joints.
    public var headLink: SCNNode? { links["head"]?.node }
    public var bodyYawNode: SCNNode? { joints["yaw_body"]?.node }
    public var leftAntennaNode: SCNNode?  { joints["left_antenna"]?.node }
    public var rightAntennaNode: SCNNode? { joints["right_antenna"]?.node }
    public var stewartActuators: [SCNNode] {
        (1...6).compactMap { joints["stewart_\($0)"]?.node }
    }

    // MARK: Init

    public init(urdfURL: URL, meshDirectoryURL: URL? = nil) throws {
        let xml = try String(contentsOf: urdfURL, encoding: .utf8)
        let meshDir = meshDirectoryURL ?? urdfURL.deletingLastPathComponent().appendingPathComponent("meshes")
        try parse(xml: xml, meshDirectory: meshDir)
    }

    // MARK: Public motion API

    /// Rotate the head as Euler angles (intrinsic XYZ in radians) — applied to the `head` link directly.
    /// This bypasses the Stewart-platform IK (the 6 leg actuators stay at zero). Use `setStewartActuators`
    /// for accurate leg motion or wire in the bundled WASM IK.
    public func setHeadEuler(roll: Float, pitch: Float, yaw: Float) {
        guard let head = headLink else { return }
        let q = simd_quatf(roll: roll, pitch: pitch, yaw: yaw)
        head.simdOrientation = q
    }

    /// Place the head with a full pose (translation + orientation) relative to its parent (`xl_330`).
    public func setHeadPose(translation: SIMD3<Float>, orientation: simd_quatf) {
        guard let head = headLink else { return }
        head.simdPosition = translation
        head.simdOrientation = orientation
    }

    /// Antenna angles in radians. Left rotates around the antenna's revolute axis, similarly for right.
    /// Antenna angles in radians, composed on top of each joint's
    /// URDF rest pose. Passing 0 leaves the antenna at its
    /// CAD-authored mounting orientation rather than snapping to the
    /// world axes.
    public func setAntennas(left: Float, right: Float) {
        if let j = joints["left_antenna"] {
            j.node.simdOrientation = j.restOrientation
                * simd_quatf(angle: left, axis: j.axis)
        }
        if let j = joints["right_antenna"] {
            j.node.simdOrientation = j.restOrientation
                * simd_quatf(angle: right, axis: j.axis)
        }
    }

    /// Body yaw — rotates the entire upper body around the foot.
    /// Composed with the joint's URDF rest pose.
    public func setBodyYaw(_ angle: Float) {
        guard let j = joints["yaw_body"] else { return }
        j.node.simdOrientation = j.restOrientation
            * simd_quatf(angle: angle, axis: j.axis)
    }

    /// Set the 6 Stewart actuator angles (radians). Indices 0..5 →
    /// joints stewart_1..stewart_6. Without computing the passive
    /// joints, the rod linkages will *not* close — the legs will
    /// look visually wrong unless you also drive the passive joints
    /// (use the bundled WASM kinematics). Composed with each joint's
    /// URDF rest pose.
    public func setStewartActuators(_ angles: [Float]) {
        for (i, angle) in angles.prefix(6).enumerated() {
            guard let joint = joints["stewart_\(i+1)"] else { continue }
            joint.node.simdOrientation = joint.restOrientation
                * simd_quatf(angle: angle, axis: joint.axis)
        }
    }

    /// Set arbitrary named joint angle. Useful when driving passive
    /// joints from external IK. Composed with the joint's URDF rest
    /// pose.
    public func setJoint(_ name: String, angle: Float) {
        guard let joint = joints[name] else { return }
        joint.node.simdOrientation = joint.restOrientation
            * simd_quatf(angle: angle, axis: joint.axis)
    }

    // MARK: - Visual cleanups for partial IK

    /// Hide the Stewart-platform rod linkage meshes. While the driver
    /// only sets `setHeadEuler` (no Stewart IK), the rods don't track
    /// the head — they stay at rest while the upper plate moves
    /// elsewhere. Hiding them keeps the visual honest.
    ///
    /// CRUCIAL: hide only the *geometry child nodes*, not the link
    /// nodes themselves. `stewart_link_rod_6` is load-bearing — it's
    /// the parent in the kinematic chain that carries `xl_330` (and
    /// therefore the head + antennas + upper plate) up via
    /// `passive_7_x → passive_7_y → passive_7_z`. Hiding the link
    /// node would hide every descendant in SceneKit, taking the
    /// entire upper half of the bot with it. Hiding only the visual
    /// child preserves the transform chain.
    public func setStewartLinkageHidden(_ hidden: Bool) {
        let prefixes = ["stewart_link_rod"]
        for link in links.values {
            let name = link.name
            guard prefixes.contains(where: { name.hasPrefix($0) }) else {
                continue
            }
            // Each visual mesh added in `parse(...)` is a direct
            // child of the link node — they're the only children we
            // attached, so hiding all of them just hides the rendered
            // rod without disturbing any joint nodes parented below.
            for child in link.node.childNodes {
                child.isHidden = hidden
            }
        }
    }

    // MARK: URDF model

    public final class Link {
        public let name: String
        public let node: SCNNode
        init(name: String) {
            self.name = name
            self.node = SCNNode()
            self.node.name = name
        }
    }

    public final class Joint {
        public let name: String
        public let type: String   // "revolute" | "fixed" | "continuous" | ...
        public let axis: SIMD3<Float>
        public let node: SCNNode  // joint node sits between parent link's node and child link's node
        /// URDF `<origin rpy="...">` for this joint, captured at load
        /// time. Motion API methods compose `restOrientation * rotation`
        /// so a zero-angle setAntennas/setBodyYaw leaves the joint at
        /// its CAD mounting pose instead of snapping to world axes.
        public var restOrientation: simd_quatf =
            simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        init(name: String, type: String, axis: SIMD3<Float>) {
            self.name = name
            self.type = type
            self.axis = axis
            self.node = SCNNode()
            self.node.name = name
        }
    }

    // MARK: URDF parsing

    private func parse(xml: String, meshDirectory: URL) throws {
        let parser = URDFParser()
        parser.parse(xml: xml)

        // Build links
        for ld in parser.links {
            let link = Link(name: ld.name)
            for visual in ld.visuals {
                let meshURL = meshDirectory.appendingPathComponent(visual.meshFile)
                if let geometry = try? Self.loadGeometry(from: meshURL, color: visual.color) {
                    let g = SCNNode(geometry: geometry)
                    applyOrigin(to: g, xyz: visual.xyz, rpy: visual.rpy)
                    link.node.addChildNode(g)
                }
            }
            links[ld.name] = link
        }

        // Build joints, attach to scene graph
        for jd in parser.joints {
            let joint = Joint(name: jd.name, type: jd.type, axis: jd.axis)
            applyOrigin(to: joint.node, xyz: jd.originXYZ, rpy: jd.originRPY)
            joint.restOrientation = joint.node.simdOrientation

            guard let parentLink = links[jd.parent], let childLink = links[jd.child] else { continue }
            // joint node is child of parent link's node, and child link's node is child of joint node
            parentLink.node.addChildNode(joint.node)
            joint.node.addChildNode(childLink.node)
            joints[jd.name] = joint
        }

        // Attach root link to our rootNode
        let rootName = parser.rootLinkName ?? parser.links.first?.name
        if let rn = rootName, let rootLink = links[rn] {
            rootNode.addChildNode(rootLink.node)
        }

        // SceneKit's default coordinate convention is Y-up but URDF is Z-up.
        // Rotate the root so the model stands upright in scenes that assume Y-up.
        rootNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
    }

    private func applyOrigin(to node: SCNNode, xyz: SIMD3<Float>, rpy: SIMD3<Float>) {
        node.simdPosition = xyz
        // URDF rpy is intrinsic XYZ Tait-Bryan (roll-pitch-yaw)
        let q = simd_quatf(roll: rpy.x, pitch: rpy.y, yaw: rpy.z)
        node.simdOrientation = q
    }

    private static func loadGeometry(from url: URL, color: SIMD4<Float>?) throws -> SCNGeometry {
        // STL → Model I/O → SCNGeometry
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil)
        guard let mesh = (asset.object(at: 0) as? MDLMesh) ?? findMesh(in: asset) else {
            throw NSError(domain: "ReachyMini", code: 1, userInfo: [NSLocalizedDescriptionKey: "No mesh in \(url.lastPathComponent)"])
        }
        let geometry = SCNGeometry(mdlMesh: mesh)
        if let c = color {
            let mat = SCNMaterial()
            #if os(macOS)
            mat.diffuse.contents = NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
            #else
            mat.diffuse.contents = UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
            #endif
            mat.lightingModel = .physicallyBased
            mat.metalness.contents = 0.0
            mat.roughness.contents = 0.6
            geometry.firstMaterial = mat
        }
        return geometry
    }

    private static func findMesh(in asset: MDLAsset) -> MDLMesh? {
        for i in 0..<asset.count {
            if let m = asset.object(at: i) as? MDLMesh { return m }
        }
        return nil
    }
}

// MARK: - Quaternion helper

extension simd_quatf {
    /// Build a quaternion from URDF roll/pitch/yaw (intrinsic XYZ rotations).
    init(roll: Float, pitch: Float, yaw: Float) {
        let qx = simd_quatf(angle: roll,  axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: pitch, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: yaw,   axis: SIMD3<Float>(0, 0, 1))
        // URDF order: R = Rz · Ry · Rx (intrinsic xyz = extrinsic zyx)
        self = qz * qy * qx
    }
}

// MARK: - URDF parser (minimal)

fileprivate final class URDFParser: NSObject, XMLParserDelegate {

    struct VisualData {
        var meshFile: String = ""
        var xyz: SIMD3<Float> = .zero
        var rpy: SIMD3<Float> = .zero
        var color: SIMD4<Float>? = nil
    }
    struct LinkData {
        var name: String = ""
        var visuals: [VisualData] = []
    }
    struct JointData {
        var name: String = ""
        var type: String = "fixed"
        var parent: String = ""
        var child: String = ""
        var originXYZ: SIMD3<Float> = .zero
        var originRPY: SIMD3<Float> = .zero
        var axis: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    }

    private(set) var links: [LinkData] = []
    private(set) var joints: [JointData] = []
    var rootLinkName: String?

    private var currentLink: LinkData?
    private var currentJoint: JointData?
    private var currentVisual: VisualData?
    private var insideVisual = false
    private var insideMaterial = false

    func parse(xml: String) {
        let parser = XMLParser(data: xml.data(using: .utf8) ?? Data())
        parser.delegate = self
        parser.parse()
        deduceRoot()
    }

    private func deduceRoot() {
        var children = Set<String>()
        for j in joints { children.insert(j.child) }
        for l in links where !children.contains(l.name) {
            rootLinkName = l.name
            return
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        switch elementName {
        case "link":
            currentLink = LinkData(name: attributes["name"] ?? "")
        case "joint":
            currentJoint = JointData()
            currentJoint?.name = attributes["name"] ?? ""
            currentJoint?.type = attributes["type"] ?? "fixed"
        case "visual":
            insideVisual = true
            currentVisual = VisualData()
        case "origin":
            let xyz = parseVec3(attributes["xyz"]) ?? .zero
            let rpy = parseVec3(attributes["rpy"]) ?? .zero
            if insideVisual {
                currentVisual?.xyz = xyz
                currentVisual?.rpy = rpy
            } else if currentJoint != nil {
                currentJoint?.originXYZ = xyz
                currentJoint?.originRPY = rpy
            }
        case "mesh" where insideVisual:
            // filename is like "meshes/foo.stl" — keep just the basename
            let f = attributes["filename"] ?? ""
            let base = (f as NSString).lastPathComponent
            currentVisual?.meshFile = base
        case "parent" where currentJoint != nil:
            currentJoint?.parent = attributes["link"] ?? ""
        case "child" where currentJoint != nil:
            currentJoint?.child = attributes["link"] ?? ""
        case "axis" where currentJoint != nil:
            if let v = parseVec3(attributes["xyz"]) { currentJoint?.axis = v }
        case "color" where insideVisual:
            currentVisual?.color = parseVec4(attributes["rgba"])
        case "material":
            insideMaterial = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "link":
            if let l = currentLink { links.append(l) }
            currentLink = nil
        case "joint":
            if let j = currentJoint { joints.append(j) }
            currentJoint = nil
        case "visual":
            if let v = currentVisual, !v.meshFile.isEmpty { currentLink?.visuals.append(v) }
            currentVisual = nil
            insideVisual = false
        case "material":
            insideMaterial = false
        default:
            break
        }
    }

    private func parseVec3(_ s: String?) -> SIMD3<Float>? {
        guard let s = s else { return nil }
        let parts = s.split(separator: " ").compactMap { Float($0) }
        guard parts.count == 3 else { return nil }
        return SIMD3<Float>(parts[0], parts[1], parts[2])
    }
    private func parseVec4(_ s: String?) -> SIMD4<Float>? {
        guard let s = s else { return nil }
        let parts = s.split(separator: " ").compactMap { Float($0) }
        guard parts.count == 4 else { return nil }
        return SIMD4<Float>(parts[0], parts[1], parts[2], parts[3])
    }
}
