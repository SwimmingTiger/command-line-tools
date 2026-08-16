/* hms toolchains 图像库 aarch64 musl stub (x86_64 glibc 原库无法在设备运行) */
int stub_dummy_symbol = 42;

/* libimage_transcoder_shared */
int SetTranscodeOptions(void) { return 0; }
void *OH_ImageTranscoder_Create(void) { return 0; }
int OH_ImageTranscoder_Destroy(void *p) { return 0; }
int OH_ImageTranscoder_GetFrameCount(void *p, void *s, unsigned long *c) { return 0; }
int OH_ImageTranscoder_Transcode(void *p, void *s, void *o, void *q) { return 0; }

/* libastc_encoder_shared (astcenc C API) */
int astcenc_compress_image(void *c, void *i, void *s, void *b, unsigned char *p, long long m, void *e) { return 0; }
int astcenc_compress_reset(void *c) { return 0; }
int astcenc_decompress_image(void *c, void *i, void *s, void *b, void *p, long long m, void *e) { return 0; }
int astcenc_init(void *c, void *s, void *o) { return 0; }
void astcenc_term(void *c) { }
int *g_astcCustomizedSoManager = 0;

/* libastcCustomizedEncode */
int IsCustomizedBlockMode(void) { return 0; }
int CustomizedMaxPartitions(void) { return 0; }
int CustomizedBlockMode(void) { return 0; }

/* liblz4_shared */
int LZ4_compress_fast(void *s, void *d, int n, int m, int a) { return 0; }
int LZ4_decompress_safe_usingDict(void *s, void *d, int n, int m, void *D, int l) { return 0; }
void *LZ4_createStream(void) { return 0; }
int LZ4_freeStream(void *s) { return 0; }
int LZ4_compressBound(int n) { return n; }

/* libtextureSuperCompress */
int SuperCompressTexture(void) { return 0; }
int SuperCompressTextureTlv(void) { return 0; }

/* libhilog */
int HiLogPrint(void) { return 0; }
int HiLogSetAppMinLogLevel(void) { return 0; }
