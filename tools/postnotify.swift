// postnotify <name> <object>
// Posts a DistributedNotificationCenter notification, so the app's DEBUG hook can be driven from a shell.
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: postnotify <notification-name> <object>")
    exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(args[1]), object: args[2], userInfo: nil, deliverImmediately: true)
Thread.sleep(forTimeInterval: 0.3)
