import UIKit
import Peertalk

struct Example {
	struct Settings {
		static let port: in_port_t = 2345
	}
	enum Frame: UInt32 {
		case deviceInfo = 100
		case message = 101
		case ping = 102
		case pong = 103
	}
}

final class ViewController: UIViewController {
	@IBOutlet private var stackView: UIStackView!
	@IBOutlet private var textView: UITextView!
	@IBOutlet private var textField: UITextField!
	@IBOutlet private var bottomConstraint: NSLayoutConstraint!

	private var serverChannel: PTChannel?
	private var peerChannel: PTChannel?

	override func viewDidLoad() {
		super.viewDidLoad()
		NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
		textField.becomeFirstResponder()

		// Create a new channel that is listening on our IPv4 port
		let channel = PTChannel(protocol: nil, delegate: self)
		channel.listen(on: Example.Settings.port, IPv4Address: INADDR_LOOPBACK) { error in
			if let error = error {
				self.append(output: "Failed to listen on 127.0.0.1:\(Example.Settings.port) \(error)")
			} else {
				self.append(output: "Listening on 127.0.0.1:\(Example.Settings.port)")
				self.serverChannel = channel
			}
		}
	}

	@objc func keyboardWillShow(notification: Notification) {
		guard let keyboardEndFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
			return
		}
		bottomConstraint.constant = -keyboardEndFrame.height
	}

	func send(message: String) {
		if let peerChannel = peerChannel {
			var m = message
			let payload = m.withUTF8 { buffer -> Data in
				var data = Data()
				data.append(CFSwapInt32HostToBig(UInt32(buffer.count)).data)
				data.append(buffer)
				return data
			}
			peerChannel.sendFrame(type: Example.Frame.message.rawValue, tag: 0, payload: payload, callback: nil)
		} else {
			append(output: "Cannot send message - not connected")
		}
	}

	func append(output message: String) {
		var text = textView.text ?? ""
		if text.count == 0 {
			text.append(message)
		} else {
			text.append("\n\(message)")
		}
		textView.text = text
		textView.scrollRangeToVisible(NSRange(location: text.count, length: 0))
	}
}

extension ViewController: UITextFieldDelegate {
	func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		guard peerChannel != nil,
					let message = textField.text else {
			return false
		}
		send(message: message)
		textField.text = nil
		return true
	}
}

extension ViewController: PTChannelDelegate {
	func channel(_ channel: PTChannel, didRecieveFrame type: UInt32, tag: UInt32, payload: Data?) {
		if let type = Example.Frame(rawValue: type) {
			switch type {
			case .message:
				guard let payload = payload else {
					return
				}
				payload.withUnsafeBytes { buffer in
					let textBytes = buffer[(buffer.startIndex + MemoryLayout<UInt32>.size)...]
					if let message = String(bytes: textBytes, encoding: .utf8) {
					  append(output: "[\(channel.userInfo)] \(message)")
					}
				}
			case .ping:
				peerChannel?.sendFrame(type: Example.Frame.pong.rawValue, tag: 0, payload: nil, callback: nil)
			default:
				break
			}
		}
	}

	func channel(_ channel: PTChannel, shouldAcceptFrame type: UInt32, tag: UInt32, payloadSize: UInt32) -> Bool {
		guard channel == peerChannel else {
			return false
		}
		guard let frame = Example.Frame(rawValue: type),
					frame == .ping || frame == .message else {
			print("Unexpected frame of type: \(type)")
			return false
		}
			return true
	}

	func channel(_ channel: PTChannel, didAcceptConnection otherChannel: PTChannel, from address: PTAddress) {
		peerChannel?.cancel()
		peerChannel = otherChannel
		peerChannel?.userInfo = address
		self.append(output: "Connected to \(address)")
	}

	func channelDidEnd(_ channel: PTChannel, error: Error?) {
		if let error = error {
			append(output: "\(channel) ended with \(error)")
		} else {
			append(output: "Disconnected from \(channel.userInfo)")
		}
	}
}

extension FixedWidthInteger {
	var data: Data {
		var bytes = self
		return Data(bytes: &bytes, count: MemoryLayout.size(ofValue: self))
	}
}
