import Foundation
import CoreGraphics
import ImageIO
import Vision
import Telemetry
import RockyKit

/// On-disk library of enrolled people with their face samples and a
/// pronunciation hint for TTS.
///
/// Storage layout (`~/Library/Application Support/Rocky/face-library.json`):
///   { "people": [ { id, name, pronunciation, samples_b64: [..], dateEnrolled } ] }
///
/// Identification uses Apple Vision's `GenerateImageFeaturePrintRequest` —
/// we crop the largest detected face out of every enrollment photo,
/// generate a feature print, and keep those prints in memory. To identify
/// a frame, the caller hands us a feature print computed from the live
/// face crop and we return the closest enrolled person whose distance is
/// below the accept threshold.
public actor FaceLibrary {
    public struct Person: Sendable, Codable, Identifiable, Equatable {
        public let id: UUID
        public var name: String
        /// Phonetic spelling sent to TTS. Falls back to `name` if empty.
        public var pronunciation: String
        public var samplesB64: [String]
        public var dateEnrolled: Date

        public init(id: UUID = UUID(),
                    name: String,
                    pronunciation: String = "",
                    samplesB64: [String] = [],
                    dateEnrolled: Date = Date()) {
            self.id = id
            self.name = name
            self.pronunciation = pronunciation
            self.samplesB64 = samplesB64
            self.dateEnrolled = dateEnrolled
        }

        /// What the TTS should pronounce — pronunciation field, or name as
        /// the fallback if the user didn't set one.
        public var spokenName: String {
            let trimmed = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? name : trimmed
        }

        /// JPEG `Data` for each sample, decoded lazily from base64.
        public var sampleData: [Data] {
            samplesB64.compactMap { Data(base64Encoded: $0) }
        }
    }

    public struct Match: Sendable, Equatable {
        public let person: Person
        public let distance: Double
    }

    public struct Snapshot: Sendable, Equatable {
        public let people: [Person]
    }

    // MARK: - State

    private var people: [Person] = []
    /// Pre-computed feature prints per person, keyed by Person.id. Not
    /// Sendable so it stays on the actor.
    private var prints: [UUID: [Vision.FeaturePrintObservation]] = [:]
    /// Match accept threshold (smaller = more selective). Apple's image
    /// feature print distances cluster <0.5 for the same scene/face and
    /// >1.0 for unrelated images. 0.85 is a moderate threshold; will
    /// likely tune lower (0.7) once we've enrolled a few real faces.
    public var acceptThreshold: Double = 0.85

    private let storeURL: URL
    private let logBus: LogBus

    // MARK: - Init

    public init(logBus: LogBus, storeURL: URL? = nil) {
        self.logBus = logBus
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let rocky = support.appendingPathComponent("Rocky", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: rocky, withIntermediateDirectories: true
            )
            self.storeURL = rocky.appendingPathComponent("face-library.json")
        }
    }

    // MARK: - Persistence

    private struct OnDisk: Codable { var people: [Person] }

    public func loadFromDisk() async {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(OnDisk.self, from: data)
        else {
            people = []
            prints = [:]
            return
        }
        people = decoded.people
        var rebuilt: [UUID: [Vision.FeaturePrintObservation]] = [:]
        for p in decoded.people {
            var ps: [Vision.FeaturePrintObservation] = []
            for jpeg in p.sampleData {
                if let pr = await Self.generatePrint(jpeg: jpeg) {
                    ps.append(pr)
                }
            }
            rebuilt[p.id] = ps
        }
        prints = rebuilt
        await logBus.publish(.sidecarLog(
            sidecar: "face-library", level: .info,
            message: "loaded \(people.count) enrolled face(s)",
            fields: [:]
        ))
    }

    public func saveToDisk() async {
        let payload = OnDisk(people: people)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Public API

    public func snapshot() -> Snapshot {
        Snapshot(people: people)
    }

    public func setAcceptThreshold(_ t: Double) {
        acceptThreshold = max(0.1, min(2.0, t))
    }

    /// Update an existing person's name or pronunciation in place.
    public func update(id: UUID, name: String, pronunciation: String) async {
        guard let idx = people.firstIndex(where: { $0.id == id }) else { return }
        people[idx].name = name
        people[idx].pronunciation = pronunciation
        await saveToDisk()
    }

    public func remove(id: UUID) async {
        people.removeAll { $0.id == id }
        prints[id] = nil
        await saveToDisk()
    }

    /// Enroll a new person from one or more photo JPEG blobs. We detect
    /// the largest face in each photo, crop with a 30% margin, encode the
    /// crop as JPEG, and stash both the JPEG (for re-load) and the
    /// generated feature print (in memory).
    @discardableResult
    public func enroll(name: String,
                       pronunciation: String,
                       photoJPEGs: [Data]) async -> Person? {
        var samplesB64: [String] = []
        var ps: [Vision.FeaturePrintObservation] = []
        for src in photoJPEGs {
            guard let cropped = await Self.cropLargestFace(from: src) else {
                await logBus.publish(.sidecarLog(
                    sidecar: "face-library", level: .warn,
                    message: "no face found in enrollment photo (skipping)",
                    fields: [:]
                ))
                continue
            }
            guard let pr = await Self.generatePrint(jpeg: cropped) else { continue }
            samplesB64.append(cropped.base64EncodedString())
            ps.append(pr)
        }
        guard !samplesB64.isEmpty else {
            await logBus.publish(.error(
                scope: "face-library",
                message: "enroll failed: no usable face crops in supplied photos",
                recoverable: true
            ))
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let person = Person(
            id: UUID(),
            name: trimmedName.isEmpty ? "Unnamed" : trimmedName,
            pronunciation: pronunciation.trimmingCharacters(in: .whitespacesAndNewlines),
            samplesB64: samplesB64
        )
        people.append(person)
        prints[person.id] = ps
        await saveToDisk()
        await logBus.publish(.sidecarLog(
            sidecar: "face-library", level: .info,
            message: "enrolled \(person.name) with \(samplesB64.count) sample(s)",
            fields: [:]
        ))
        return person
    }

    /// Generate a feature print directly from a CGImage of a face crop.
    /// Caller (MacFaceTracker) does this so it can hand the result to
    /// `identify(_:)` without copying JPEG bytes. New Swift Vision
    /// `GenerateImageFeaturePrintRequest.Result` is a single observation
    /// (not an array).
    public func generatePrint(cgImage: CGImage) async -> Vision.FeaturePrintObservation? {
        try? await Vision.GenerateImageFeaturePrintRequest().perform(on: cgImage)
    }

    /// Identify the person whose enrolled samples most resemble the given
    /// feature print. Returns the closest match within `acceptThreshold`,
    /// or nil if no enrolled face is close enough.
    public func identify(_ observation: Vision.FeaturePrintObservation) -> Match? {
        var best: (Person, Double)?
        for person in people {
            guard let ps = prints[person.id], !ps.isEmpty else { continue }
            var minD = Double.infinity
            for p in ps {
                if let d = try? observation.distance(to: p) {
                    let dd = Double(d)
                    if dd < minD { minD = dd }
                }
            }
            if minD < (best?.1 ?? .infinity) {
                best = (person, minD)
            }
        }
        guard let b = best, b.1 <= acceptThreshold else { return nil }
        return Match(person: b.0, distance: b.1)
    }

    // MARK: - Helpers

    /// Run face detection on the source JPEG, crop the largest face with
    /// a 30% margin, return the cropped JPEG.
    private static func cropLargestFace(from jpeg: Data) async -> Data? {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let cgImage = CGImage(
                jpegDataProviderSource: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        let request = Vision.DetectFaceRectanglesRequest()
        guard let observations = try? await request.perform(on: cgImage),
              let largest = observations.max(by: {
                  $0.boundingBox.cgRect.width * $0.boundingBox.cgRect.height
                < $1.boundingBox.cgRect.width * $1.boundingBox.cgRect.height
              })
        else { return nil }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let bb = largest.boundingBox.cgRect
        let pxRect = CGRect(
            x: bb.origin.x * imgW,
            y: (1.0 - bb.origin.y - bb.size.height) * imgH,
            width: bb.size.width * imgW,
            height: bb.size.height * imgH
        )
        let mx = pxRect.width * 0.30
        let my = pxRect.height * 0.30
        let expanded = pxRect.insetBy(dx: -mx, dy: -my)
            .intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard let cropped = cgImage.cropping(to: expanded) else { return nil }
        return cgImageToJPEG(cropped, quality: 0.85)
    }

    private static func generatePrint(jpeg: Data) async -> Vision.FeaturePrintObservation? {
        guard let provider = CGDataProvider(data: jpeg as CFData),
              let cgImage = CGImage(
                jpegDataProviderSource: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }
        return try? await Vision.GenerateImageFeaturePrintRequest().perform(on: cgImage)
    }

    private static func cgImageToJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            buffer as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buffer as Data
    }
}
