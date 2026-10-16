import Foundation
import GridCore

/// Replays bounded packet captures without an event tap, desktop access, or user-state writes.
enum GestureReplay {
    static func run(input:URL,output:URL) throws {
        let data = try Data(contentsOf:input)
        guard data.count <= 40_000_000 else { throw GridError.invalid("La captura supera el límite de 40 MB") }
        var recognizer = ContactFrameRecognizer(), results:[[String:Any]] = []
        var packets = 0, steps = 0, ends = 0, cancellations = 0, lastSequence = 0, suppressedScrollPackets = 0
        var generation:Int?
        for line in String(decoding:data,as:UTF8.self).split(separator:"\n") {
            guard let packet = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw GridError.invalid("Paquete de captura inválido") }
            if packet["kind"] as? String == "suppressed-scroll" { suppressedScrollPackets += 1; continue }
            guard let timestamp = packet["timestamp"] as? Double,
                  let samples = packet["touches"] as? [[String:Any]],
                  let invert = packet["invert"] as? Bool,
                  let threshold = packet["threshold"] as? Double else { throw GridError.invalid("Paquete de captura inválido") }
            let sequence = packet["seq"] as? Int ?? packets+1
            let currentGeneration = packet["generation"] as? Int
            if sequence <= lastSequence || currentGeneration != generation { recognizer.reset() }
            lastSequence = sequence; generation = currentGeneration
            let contacts = try samples.map { sample -> TouchContact in
                guard let id = sample["id"], let x = sample["x"] as? Double, let y = sample["y"] as? Double,
                      let name = sample["phase"] as? String else { throw GridError.invalid("Contacto de captura inválido") }
                let phase:TouchPhase
                switch name {
                case "began":phase = .began
                case "moved":phase = .moved
                case "stationary":phase = .stationary
                case "ended":phase = .ended
                case "cancelled":phase = .cancelled
                default:throw GridError.invalid("Fase de contacto desconocida")
                }
                return TouchContact(sample:TouchSample(id:String(describing:id),x:x,y:y),phase:phase,resting:sample["resting"] as? Bool ?? false)
            }
            let events:[ContactGestureEvent]
            if packet["kind"] as? String == "settlement" {
                events = recognizer.advance(timestamp:timestamp)
            } else {
                let endMarker = contacts.isEmpty && ((packet["phase"] as? Int ?? 0)&8 != 0)
                events = recognizer.feed(contacts,ended:endMarker,modifiers:packet["modifiers"] as? Int ?? 0,displayID:"replay",
                    threshold:threshold,invert:invert,timestamp:timestamp)
            }
            packets += 1
            for event in events {
                var result:[String:Any] = ["seq":sequence,"timestamp":timestamp]
                switch event {
                case .step(let swipe):result["event"] = "step"; result["direction"] = swipe.direction.rawValue; result["fingers"] = swipe.fingers;steps += 1
                case .ended:result["event"] = "ended";ends += 1
                case .cancelled:result["event"] = "cancelled";cancellations += 1
                }
                results.append(result)
            }
        }
        let report:[String:Any] = ["packets":packets,"steps":steps,"ends":ends,"cancellations":cancellations,"suppressedScrollPackets":suppressedScrollPackets,
            "events":results,"usesPhysicalInput":false,"writesUserState":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }
}
