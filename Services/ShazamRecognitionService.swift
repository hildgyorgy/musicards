//
//  ShazamRecognitionService.swift
//  MusiCards
//

import Foundation

#if os(iOS)
import AVFAudio
import ShazamKit

struct ShazamMatch {
    let title: String
    let artist: String
    let album: String?
    let appleMusicID: String?
    let trackLengthMilliseconds: Int?
}

enum ShazamRecognitionError: Error {
    case microphonePermissionDenied
    case noMatch
    case missingTitleOrArtist
}

final class ShazamRecognitionService: NSObject, SHSessionDelegate {

    private let session = SHSession()
    private let audioEngine = AVAudioEngine()

    private var continuation: CheckedContinuation<ShazamMatch, Error>?
    private var hasFinishedRecognition = false

    override init() {
        super.init()
        session.delegate = self
    }

    func recognize() async throws -> ShazamMatch {
        try await requestMicrophonePermission()
        
        hasFinishedRecognition = false

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            do {
                try self.startListening()
            } catch {
                self.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func finish(with result: Result<ShazamMatch, Error>) {
        guard !hasFinishedRecognition else { return }

        hasFinishedRecognition = true
        stopListening()

        switch result {
        case .success(let match):
            continuation?.resume(returning: match)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }

        continuation = nil
    }

    private func requestMicrophonePermission() async throws {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard granted else {
            throw ShazamRecognitionError.microphonePermissionDenied
        }
    }

    private func startListening() throws {
        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(.record)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: recordingFormat
        ) { [weak self] buffer, audioTime in
            self?.session.matchStreamingBuffer(buffer, at: audioTime)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        stopListening()

        guard let item = match.mediaItems.first else {
            continuation?.resume(throwing: ShazamRecognitionError.noMatch)
            continuation = nil
            return
        }

        guard let title = item.title,
              let artist = item.artist,
              !title.isEmpty,
              !artist.isEmpty
        else {
            finish(with: .failure(ShazamRecognitionError.missingTitleOrArtist))
            return
        }

        let result = ShazamMatch(
            title: title,
            artist: artist,
            album: item.subtitle,
            appleMusicID: item.appleMusicID,
            trackLengthMilliseconds: extractTrackLengthMilliseconds(from: item.webURL)
        )

        finish(with: .success(result))
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        finish(with: .failure(error ?? ShazamRecognitionError.noMatch))
    }

    private func extractTrackLengthMilliseconds(from url: URL?) -> Int? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "trackLength" })?.value
        else {
            return nil
        }

        return Int(value)
    }
}
#endif
