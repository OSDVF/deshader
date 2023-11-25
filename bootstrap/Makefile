all: abi

../zig-out/lib/deshader.c:
	cd .. && zig build deshader -DwolfSSL=true -Dofmt=c
	printf '%s\n%s\n%s\n' '#define zig_never_tail' '#define zig_always_tail" "$(cat ../zig-out/lib/deshader.c)" > ../zig-out/lib/deshader.c

libdeshader.so:	../zig-out/lib/deshader.c
	gcc -o libdeshader.so -std=c99 -fPIC -rdynamic -shared -I/usr/lib/zig/lib/ -Dzig_always_tail -Dzig_never_tail ../zig-out/lib/deshader.c -lwebkit2gtk-4.0 -lwolfssl

abi:	libdeshader.so:
	g++ -o abi -std=c++17 -L. -ldeshader `pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.0` ../libs/positron/src/wv/webview.cpp ../examples/abi.cpp -I ../zig-out/include