module dropo

go 1.27.4

require (
	dropocore v0.0.0
	github.com/energye/systray v1.0.3
	github.com/metacubex/utls v1.8.4
	golang.org/x/net v0.62.0
	golang.org/x/sys v0.49.0
)

replace dropocore => ./mobile/dropocore

require (
	github.com/andybalholm/brotli v1.2.7 // indirect
	github.com/godbus/dbus/v5 v5.1.0 // indirect
	github.com/klauspost/compress v1.20.2 // indirect
	golang.org/x/crypto v0.58.1-0.20261009181718-2f1f834330b2 // indirect
	golang.org/x/exp v0.0.0-20240904232852-e7e105dedf7e // indirect
	golang.org/x/text v0.43.0 // indirect
)
