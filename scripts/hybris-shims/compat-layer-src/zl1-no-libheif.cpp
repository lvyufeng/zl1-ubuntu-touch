/* zl1-no-libheif.cpp -- the one symbol that kept libis_compat_layer.so from building without
 * libheif, and with libheif the whole audio stack in a camera process. Copied into
 * halium/libhybris/compat/input/ by build-compat-layer.sh, which also adds it to LOCAL_SRC_FILES.
 *
 * What it is. libskia's SkHeifCodec.o is part of the static libskia this module links (the codec
 * registry table in skia references it, so it cannot be left out), and it has exactly one
 * dependency outside skia and libc++:
 *
 *     U _Z17createHeifDecoderv        (llvm-nm -u SkHeifCodec.o)
 *
 * -- `createHeifDecoder()`, which libheif.so provides. Linking libheif was the obvious thing and it
 * is what the first build did. It is also why every camera run that started the input stack died of
 * SIGSEGV: a DT_NEEDED is transitive, and this is what libheif.so drags in on this device --
 *
 *     libis_compat_layer.so -> libheif.so -> libmedia.so -> libavenhancements.so
 *
 * -- where libavenhancements.so is a *vendor* prebuilt that imports
 *
 *     cannot locate symbol "_ZN7android9AVFactory17createMediaFilterEv"
 *       referenced by "/android/system/lib64/libavenhancements.so"
 *
 * and nothing on the device provides it (no libavenhancements source in this tree, no such symbol
 * anywhere in /system/lib64). hybris' android_dlopen does not NULL-check what it fails to load, so
 * a symbol that cannot be resolved is not an error message but a jump to NULL a few instructions
 * later: test_camera exited 139 with an empty stdout, having printed nothing at all.
 *
 * Returning nullptr is not a workaround invented here: it is a path skia implements. From
 * external/skia/src/codec/SkHeifCodec.cpp:123 --
 *
 *     std::unique_ptr<HeifDecoder> heifDecoder(createHeifDecoder());
 *     if (heifDecoder.get() == nullptr) {
 *         *result = kInternalError;
 *         return nullptr;
 *     }
 *
 * so all this means is that this build has no HEIF decoder and a .heif file will not decode --
 * which costs nothing, because the only thing in this module that uses Skia is the Android input
 * stack's pointer/sprite rendering. It never decodes an image of any kind.
 *
 * The return type is deliberately not the `std::unique_ptr<HeifDecoder>` the caller believes in:
 * a function's return type is not part of its mangled name, and a unique_ptr is returned in x0 the
 * same way a pointer is, so the call site sees a null unique_ptr -- which is the case it checks
 * for. Declaring the class here (rather than including libheif's header) is what keeps libheif out
 * of the include path as well as out of the link. */

class HeifDecoder;

HeifDecoder *createHeifDecoder();
HeifDecoder *createHeifDecoder() { return 0; }
