import AppKit

enum DockArtwork {
    private static let digits = ["111101101101111", "010110010010111", "111001111100111", "111001111001111", "101101111001001", "111100111001111", "111100111101111", "111001010010010", "111101111101111", "111101111001111"]
    static func image(_ kind: String, date: Date = Date(), size: CGFloat = 256) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { bounds in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.scaleBy(x: size/1024, y: size/1024)
            let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 188, cornerHeight: 188, transform: nil)
            c.saveGState(); c.addPath(tile); c.clip()
            let colors = [NSColor(calibratedRed: 1, green: 0.95, blue: 0.85, alpha: 1).cgColor, NSColor(calibratedRed: 0.97, green: 0.87, blue: 0.72, alpha: 1).cgColor]
            c.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,1])!, start: CGPoint(x: 150,y: 100), end: CGPoint(x: 850,y: 924), options: [])
            c.restoreGState(); c.addPath(tile); c.setStrokeColor(NSColor(calibratedRed: 0.51, green: 0.34, blue: 0.22, alpha: 0.75).cgColor); c.setLineWidth(3); c.strokePath()
            c.translateBy(x: 192, y: 192); c.scaleBy(x: 20, y: 20)
            c.setShouldAntialias(false)
            let ink = NSColor(calibratedRed: 0.25, green: 0.12, blue: 0.07, alpha: 1)
            let cream = NSColor(calibratedRed: 1, green: 0.95, blue: 0.85, alpha: 1)
            let red = NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.19, alpha: 1)
            let shadow = NSColor(calibratedRed: 0.71, green: 0.53, blue: 0.37, alpha: 1)
            func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: NSColor) { c.setFillColor(color.cgColor); c.fill(CGRect(x: x, y: y, width: w, height: h)) }
            func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ color: NSColor, _ width: Int = 1) {
                var x=x0, y=y0; let dx=abs(x1-x0), sx=x0<x1 ? 1 : -1, dy = -abs(y1-y0), sy=y0<y1 ? 1 : -1; var error=dx+dy
                while true { rect(x,y,width,width,color); if x==x1 && y==y1 { break }; let e=2*error; if e>=dy { error+=dy; x+=sx }; if e<=dx { error+=dx; y+=sy } }
            }
            switch kind {
            case "blank": break
            case "calendar":
                rect(3,5,26,25,ink); rect(2,7,28,21,ink); rect(4,6,24,23,shadow); rect(4,6,23,22,cream)
                rect(3,6,26,7,red); rect(3,12,26,2,NSColor(calibratedRed: 0.69,green: 0.13,blue: 0.08,alpha: 1)); rect(5,7,3,3,NSColor(calibratedRed: 1,green: 0.48,blue: 0.42,alpha: 1))
                for x in [8,22] { rect(x-1,1,4,8,ink); rect(x,2,2,5,cream) }
                let text=Array(String(Calendar.current.component(.day, from: date))); let start=(32-(text.count*8-2))/2
                for (index,char) in text.enumerated() { if let n=char.wholeNumberValue { for (i,bit) in digits[n].enumerated() where bit=="1" { rect(start+index*8+(i%3)*2,16+(i/3)*2,2,2,ink) } } }
            case "clock":
                for y in 1..<31 { for x in 1..<31 { let d=hypot(Double(x)-15.5,Double(y)-15.5); if d<14.7 && d>12.8 { rect(x,y,1,1,ink) } else if d<=12.8 && d>11.8 { rect(x,y,1,1,NSColor(calibratedWhite: 0.5,alpha: 1)) } } }
                for hour in 0..<12 { let a=Double(hour)*Double.pi/6; rect(Int((15.5+sin(a)*10).rounded()),Int((15.5-cos(a)*10).rounded()),hour%3==0 ? 2 : 1,hour%3==0 ? 2 : 1,ink) }
                let t=Calendar.current.dateComponents([.hour,.minute,.second],from: date)
                let h=Double(t.hour!%12)+Double(t.minute!)/60, m=Double(t.minute!)+Double(t.second!)/60
                func hand(_ angle: Double,_ length: Double,_ color: NSColor,_ width: Int) { line(15,15,Int((15+sin(angle)*length).rounded()),Int((15-cos(angle)*length).rounded()),color,width) }
                hand(h*Double.pi/6,6,ink,2); hand(m*Double.pi/30,9,ink,1); hand(Double(t.second!)*Double.pi/30,10,red,1); rect(14,14,3,3,red)
            default:
                let blue=NSColor(calibratedRed: 0.22,green: 0.66,blue: 0.86,alpha: 1)
                rect(2,5,12,5,ink); rect(2,9,28,19,ink); rect(3,7,10,4,blue); rect(3,10,26,17,blue); rect(4,11,24,3,NSColor(calibratedRed: 0.51,green: 0.84,blue: 0.95,alpha: 1)); rect(15,15,2,7,cream); rect(13,19,6,2,cream); rect(14,21,4,1,cream)
            }
            return true
        }
    }
}
