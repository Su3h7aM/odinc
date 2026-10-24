package types

import "core:strings"
import sysinfo "core:sys/info"

X86_Feature :: enum {
	X87,
	Cx8,
	Cmov,
	Mmx,
	Fxsr,
	Sse,
	Sse2,
	Cx16,
	Sahf,
	Popcnt,
	Sse3,
	Ssse3,
	Sse4_1,
	Sse4_2,
	Crc32,
	Avx,
	Avx2,
	Bmi,
	Bmi2,
	F16c,
	Fma,
	Lzcnt,
	Movbe,
	Xsave,
	Avx512f,
	Avx512bw,
	Avx512cd,
	Avx512dq,
	Avx512vl,
	Aes,
	Pclmul,
	Sha,
	Adx,
	Rdrand,
	Rdseed,
}

X86_Features :: bit_set[X86_Feature;u64]

X86_Level :: enum {
	V1,
	V2,
	V3,
	V4,
}

X86_LEVEL_SPELLINGS := [X86_Level]string {
	.V1 = "x86_64_v1",
	.V2 = "x86_64_v2",
	.V3 = "x86_64_v3",
	.V4 = "x86_64_v4",
}

X86_FEATURE_SPELLINGS := [X86_Feature]string {
	.X87      = "x87",
	.Cx8      = "cx8",
	.Cmov     = "cmov",
	.Mmx      = "mmx",
	.Fxsr     = "fxsr",
	.Sse      = "sse",
	.Sse2     = "sse2",
	.Cx16     = "cx16",
	.Sahf     = "sahf",
	.Popcnt   = "popcnt",
	.Sse3     = "sse3",
	.Ssse3    = "ssse3",
	.Sse4_1   = "sse4.1",
	.Sse4_2   = "sse4.2",
	.Crc32    = "crc32",
	.Avx      = "avx",
	.Avx2     = "avx2",
	.Bmi      = "bmi",
	.Bmi2     = "bmi2",
	.F16c     = "f16c",
	.Fma      = "fma",
	.Lzcnt    = "lzcnt",
	.Movbe    = "movbe",
	.Xsave    = "xsave",
	.Avx512f  = "avx512f",
	.Avx512bw = "avx512bw",
	.Avx512cd = "avx512cd",
	.Avx512dq = "avx512dq",
	.Avx512vl = "avx512vl",
	.Aes      = "aes",
	.Pclmul   = "pclmul",
	.Sha      = "sha",
	.Adx      = "adx",
	.Rdrand   = "rdrand",
	.Rdseed   = "rdseed",
}

X86_LEVEL_FEATURES := [X86_Level]X86_Features {
	.V1 = {.X87, .Cx8, .Cmov, .Mmx, .Fxsr, .Sse, .Sse2},
	.V2 = {.X87, .Cx8, .Cmov, .Mmx, .Fxsr, .Sse, .Sse2, .Cx16, .Sahf, .Popcnt, .Sse3, .Ssse3, .Sse4_1, .Sse4_2, .Crc32},
	.V3 = {
		.X87,
		.Cx8,
		.Cmov,
		.Mmx,
		.Fxsr,
		.Sse,
		.Sse2,
		.Cx16,
		.Sahf,
		.Popcnt,
		.Sse3,
		.Ssse3,
		.Sse4_1,
		.Sse4_2,
		.Crc32,
		.Avx,
		.Avx2,
		.Bmi,
		.Bmi2,
		.F16c,
		.Fma,
		.Lzcnt,
		.Movbe,
		.Xsave,
	},
	.V4 = {
		.X87,
		.Cx8,
		.Cmov,
		.Mmx,
		.Fxsr,
		.Sse,
		.Sse2,
		.Cx16,
		.Sahf,
		.Popcnt,
		.Sse3,
		.Ssse3,
		.Sse4_1,
		.Sse4_2,
		.Crc32,
		.Avx,
		.Avx2,
		.Bmi,
		.Bmi2,
		.F16c,
		.Fma,
		.Lzcnt,
		.Movbe,
		.Xsave,
		.Avx512f,
		.Avx512bw,
		.Avx512cd,
		.Avx512dq,
		.Avx512vl,
	},
}

@(private = "file")
x86_feature_dependencies :: proc() -> [X86_Feature]X86_Features {
	// Modeled prerequisites from LLVM's X86.td.
	dependencies :: [X86_Feature]X86_Features {
		.X87      = {},
		.Cx8      = {},
		.Cmov     = {},
		.Mmx      = {},
		.Fxsr     = {},
		.Sse      = {},
		.Sahf     = {},
		.Popcnt   = {},
		.Crc32    = {},
		.Bmi      = {},
		.Bmi2     = {},
		.Lzcnt    = {},
		.Movbe    = {},
		.Xsave    = {},
		.Adx      = {},
		.Rdrand   = {},
		.Rdseed   = {},
		.Cx16     = {.Cx8},
		.Sse2     = {.Sse},
		.Sse3     = {.Sse2},
		.Ssse3    = {.Sse3},
		.Sse4_1   = {.Ssse3},
		.Sse4_2   = {.Sse4_1},
		.Avx      = {.Sse4_2},
		.Avx2     = {.Avx},
		.F16c     = {.Avx},
		.Fma      = {.Avx},
		.Avx512f  = {.Avx2, .Fma, .F16c},
		.Avx512bw = {.Avx512f},
		.Avx512cd = {.Avx512f},
		.Avx512dq = {.Avx512f},
		.Avx512vl = {.Avx512f},
		.Aes      = {.Sse2},
		.Pclmul   = {.Sse2},
		.Sha      = {.Sse2},
	}
	return dependencies
}

x86_enabled_features :: proc(enabled: X86_Features) -> X86_Features {
	dependencies := x86_feature_dependencies()
	result := enabled
	for changed := true; changed; {
		changed = false
		for feature in result {
			missing := dependencies[feature] - result
			if missing == {} { continue }
			result |= missing
			changed = true
		}
	}
	return result
}

x86_disabled_features :: proc(disabled: X86_Features) -> X86_Features {
	dependencies := x86_feature_dependencies()
	result := disabled
	for changed := true; changed; {
		changed = false
		for feature in X86_Feature {
			if feature in result || dependencies[feature] & result == {} { continue }
			result += {feature}
			changed = true
		}
	}
	return result
}

x86_level_spelling :: proc(level: X86_Level) -> string {
	return X86_LEVEL_SPELLINGS[level]
}

parse_x86_level :: proc(spelling: string) -> (level: X86_Level, ok: bool) {
	if spelling == "native" { return native_x86_level(), true }
	for candidate in X86_Level {
		if X86_LEVEL_SPELLINGS[candidate] == spelling {
			return candidate, true
		}
	}
	return .V1, false
}

native_x86_level :: proc() -> X86_Level {
	when ODIN_ARCH == .amd64 {
		features := sysinfo.cpu_features()
		maximum_leaf, _, _, _ := sysinfo.cpuid(0, 0)
		maximum_extended_leaf, _, _, _ := sysinfo.cpuid(0x80000000, 0)
		if maximum_leaf < 1 || maximum_extended_leaf < 0x80000001 { return .V1 }
		_, _, basic, _ := sysinfo.cpuid(1, 0)
		_, _, extended, _ := sysinfo.cpuid(0x80000001, 0)
		level_two := sysinfo.CPU_Features{.sse3, .ssse3, .sse41, .sse42, .popcnt}
		if features & level_two != level_two || basic & (1 << 13) == 0 || extended & 1 == 0 { return .V1 }
		level_three := sysinfo.CPU_Features{.avx, .avx2, .bmi1, .bmi2, .fma, .os_xsave}
		level_three_basic :: u32((1 << 22) | (1 << 26) | (1 << 29))
		if features & level_three != level_three || basic & level_three_basic != level_three_basic || extended & (1 << 5) == 0 { return .V2 }
		level_four := sysinfo.CPU_Features{.avx512f, .avx512bw, .avx512cd, .avx512dq, .avx512vl}
		if features & level_four != level_four { return .V3 }
		return .V4
	} else {
		return .V1
	}
}

x86_level_features :: proc(level: X86_Level) -> X86_Features {
	return X86_LEVEL_FEATURES[level]
}

parse_x86_feature :: proc(name: string) -> (feature: X86_Feature, ok: bool) {
	for candidate in X86_Feature {
		if X86_FEATURE_SPELLINGS[candidate] == name {
			return candidate, true
		}
	}
	switch name {
	case "sse4_1":
		return .Sse4_1, true
	case "sse4_2":
		return .Sse4_2, true
	case "bmi1":
		return .Bmi, true
	case "pclmulqdq":
		return .Pclmul, true
	case "rdrnd":
		return .Rdrand, true
	}
	return .X87, false
}

x86_features_list :: proc(features: X86_Features, allocator := context.allocator) -> []string {
	count := 0
	for feature in X86_Feature {
		if feature in features {
			count += 1
		}
	}
	list := make([]string, count, allocator)
	index := 0
	for feature in X86_Feature {
		if feature in features {
			list[index] = X86_FEATURE_SPELLINGS[feature]
			index += 1
		}
	}
	return list
}

// Known names from Odin build_settings_microarch.cpp; instruction selection uses the modeled hardware bits.
target_feature_known :: proc(name: string, x86_only: bool = false) -> bool {
	x86_names :: "16bit-mode,32bit-mode,64bit,64bit-mode,adx,aes,allow-light-256-bit,amx-avx512,amx-bf16,amx-complex,amx-fp16,amx-fp8,amx-int8,amx-movrs,amx-tile,avx,avx10.1,avx10.1-512,avx10.2,avx10.2-512,avx2,avx512bf16,avx512bitalg,avx512bmm,avx512bw,avx512cd,avx512dq,avx512f,avx512fp16,avx512ifma,avx512vbmi,avx512vbmi2,avx512vl,avx512vnni,avx512vp2intersect,avx512vpopcntdq,avxifma,avxneconvert,avxvnni,avxvnniint16,avxvnniint8,bmi,bmi2,branch-hint,branchfusion,ccmp,cf,cldemote,clflushopt,clwb,clzero,cmov,cmpccxadd,crc32,cx16,cx8,egpr,enqcmd,ermsb,evex512,f16c,false-deps-bls,false-deps-compress,false-deps-expand,false-deps-getmant,false-deps-lzcnt,false-deps-mulc,false-deps-mullq,false-deps-perm,false-deps-popcnt,false-deps-range,false-deps-tzcnt,fast-11bytenop,fast-15bytenop,fast-7bytenop,fast-bextr,fast-dpwssd,fast-gather,fast-hops,fast-imm16,fast-lzcnt,fast-movbe,fast-scalar-fsqrt,fast-scalar-shift-masks,fast-shld-rotate,fast-variable-crosslane-shuffle,fast-variable-perlane-shuffle,fast-vector-fsqrt,fast-vector-shift-masks,faster-shift-than-shuffle,fma,fma4,fsgsbase,fsrm,fxsr,gfni,harden-sls-ijmp,harden-sls-ret,hreset,idivl-to-divb,idivq-to-divl,inline-asm-use-gpr32,invpcid,jmpabs,kl,lea-sp,lea-uses-ag,lvi-cfi,lvi-load-hardening,lwp,lzcnt,macrofusion,mmx,movbe,movdir64b,movdiri,movrs,mwaitx,ndd,nf,no-bypass-delay,no-bypass-delay-blend,no-bypass-delay-mov,no-bypass-delay-shuffle,nopl,pad-short-functions,pclmul,pconfig,pku,popcnt,ppx,prefer-128-bit,prefer-256-bit,prefer-legacy-setcc,prefer-mask-registers,prefer-movmsk-over-vtest,prefer-ndd-mem,prefer-no-gather,prefer-no-scatter,prefetchi,prfchw,ptwrite,push2pop2,raoint,rdpid,rdpru,rdrnd,rdseed,reserve-edi,reserve-r10,reserve-r11,reserve-r12,reserve-r13,reserve-r14,reserve-r15,reserve-r16,reserve-r17,reserve-r18,reserve-r19,reserve-r20,reserve-r21,reserve-r22,reserve-r23,reserve-r24,reserve-r25,reserve-r26,reserve-r27,reserve-r28,reserve-r29,reserve-r30,reserve-r31,reserve-r8,reserve-r9,retpoline,retpoline-external-thunk,retpoline-indirect-branches,retpoline-indirect-calls,rtm,sahf,sbb-dep-breaking,serialize,seses,sgx,sha,sha512,shstk,slow-3ops-lea,slow-incdec,slow-indirect-call,slow-lea,slow-pmaddwd,slow-pmulld,slow-pmullq,slow-shld,slow-two-mem-ops,slow-unaligned-mem-16,slow-unaligned-mem-32,sm3,sm4,soft-float,sse,sse-unaligned-mem,sse2,sse3,sse4.1,sse4.2,sse4a,ssse3,tagged-globals,tbm,tsxldtrk,tuning-fast-imm-vector-shift,uintr,use-glm-div-sqrt-costs,use-slm-arith-costs,usermsr,vaes,vpclmulqdq,vzeroupper,waitpkg,wbnoinvd,widekl,x32,x87,xop,xsave,xsavec,xsaveopt,xsaves,zu"
	other_names :: "32bit,8msecext,CONTEXTIDREL2,a,a12,a15,a17,a32,a320,a35,a5,a510,a520,a520ae,a53,a55,a57,a64fx,a65,a7,a710,a715,a72,a720,a720ae,a73,a75,a76,a77,a78,a78ae,a78c,a8,a9,aapcs-frame-chain,aclass,acquire-release,addr-lsl-slow-14,aggressive-fma,aggressive-interleaving,align-cmp-csel-pairs,all,alternate-sextload-cvt-f32-pattern,altnzcv,alu-lsl-fast,am,ampere1,ampere1a,ampere1b,ampere1c,amvs,andes45,apple-a10,apple-a11,apple-a12,apple-a13,apple-a14,apple-a15,apple-a16,apple-a17,apple-a7,apple-m4,apple-m5,arith-bcc-fusion,arith-cbz-fusion,armv4,armv4t,armv5t,armv5te,armv5tej,armv6,armv6-m,armv6j,armv6k,armv6kz,armv6s-m,armv6t2,armv7-a,armv7-m,armv7-r,armv7e-m,armv7k,armv7s,armv7ve,armv8-a,armv8-m.base,armv8-m.main,armv8-r,armv8.1-a,armv8.1-m.main,armv8.2-a,armv8.3-a,armv8.4-a,armv8.5-a,armv8.6-a,armv8.7-a,armv8.8-a,armv8.9-a,armv9-a,armv9.1-a,armv9.2-a,armv9.3-a,armv9.4-a,armv9.5-a,armv9.6-a,armv9.7-a,ascend-store-address,atomics,atomics-32,avoid-ldapur,avoid-movs-shop,avoid-muls,avoid-partial-cpsr,b,balance-fp-ops,bf16,big-endian-instructions,branch-align-64,brbe,bti,btie,bulk-memory,bulk-memory-opt,c,c1-nano,c1-premium,c1-pro,c1-ultra,call-indirect-overlong,call-saved-x10,call-saved-x11,call-saved-x12,call-saved-x13,call-saved-x14,call-saved-x15,call-saved-x18,call-saved-x8,call-saved-x9,carmel,ccdp,ccidx,ccpp,cde,cdecp0,cdecp1,cdecp2,cdecp3,cdecp4,cdecp5,cdecp6,cdecp7,cheap-predicable-cpsr,chk,clrbhb,cmp-bcc-fusion,cmpbr,complxnum,conditional-cmv-fusion,cortex-a510,cortex-a710,cortex-a725,cortex-a78,cortex-a78ae,cortex-r82,cortex-r82ae,cortex-x1,cortex-x1c,cortex-x2,cortex-x3,cortex-x4,cortex-x925,cpa,crc,crypto,cssc,d,d128,d32,db,dfb,disable-distinct-predicate-dst-reg,disable-fast-inc-vl,disable-latency-sched-heuristic,disable-ldp,disable-maximize-scalable-bandwidth,disable-misched-load-clustering,disable-misched-store-clustering,disable-postmisched-load-clustering,disable-postmisched-store-clustering,disable-postra-scheduler,disable-stp,disable-unpredicated-ld-st-lower,dit,dlen-factor-2,dont-widen-vmovs,dotprod,dsp,e,ecv,el2vmsa,el3,enable-select-opt,enable-vsetvli-sched-heuristic,ete,exact-asm,exception-handling,execute-only,expand-fp-mlx,experimental,experimental-p,experimental-rvm23u32,experimental-smpmpmt,experimental-svukte,experimental-xqccmt,experimental-xsfmclic,experimental-xsfsclic,experimental-y,experimental-zibi,experimental-zicfilp,experimental-zicfiss,experimental-zvabd,experimental-zvbc32e,experimental-zvdot4a8i,experimental-zvfbdota32f,experimental-zvfbfa,experimental-zvfofp8min,experimental-zvfqwbdota8f,experimental-zvfqwdota8f,experimental-zvfwbdota16bf,experimental-zvfwdota16bf,experimental-zvkgs,experimental-zvqwbdota16i,experimental-zvqwbdota8i,experimental-zvqwdota16i,experimental-zvqwdota8i,experimental-zvvfmm,experimental-zvvmm,experimental-zvvmtls,experimental-zvvmttls,experimental-zvzip,extended-const,exynos,exynos-cheap-as-move,exynosm3,exynosm4,f,f16f32dot,f16f32mm,f16mm,f32mm,f64mm,f8f16mm,f8f32mm,falkor,faminmax,fast-ld1-single,fgt,fix-cmse-cve-2021-35465,fix-cortex-a53-835769,fix-cortex-a57-aes-1742098,fixed-load-latency-4,flagm,fmv,force-32bit-jump-tables,forced-atomics,fp-armv8,fp-armv8d16,fp-armv8d16sp,fp-armv8sp,fp16,fp16fml,fp64,fp8,fp8dot2,fp8dot4,fp8fma,fpac,fpao,fprcvt,fpregs,fpregs16,fpregs64,fptoint,fujitsu-monaka,fullfp16,fuse-address,fuse-addsub-2reg-const1,fuse-adrp-add,fuse-aes,fuse-arith-logic,fuse-crypto-eor,fuse-csel,fuse-cset,fuse-fcsel,fuse-literals,fusion-add-load,fusion-add-mem,fusion-addi-load,fusion-auipc-addi,fusion-auipc-load,fusion-bfext,fusion-ld-add,fusion-logic-imm-reg,fusion-logic-reg-imm,fusion-logic-reg-reg,fusion-lui-addi,fusion-lui-load,fusion-mul-add,fusion-qc-e-li-load-store,fusion-shift-bit-extract,fusion-shifted-zextw,fusion-shxadd-load,fusion-zexth,fusion-zextw,gc,gcie,gcs,h,harden-sls-blr,harden-sls-nocomdat,harden-sls-retbr,has-limited-64bit-vector-mul-bandwidth,hbc,hinte,hip12,hwdiv,hwdiv-arm,i,i8mm,ite,iwmmxt,iwmmxt2,jsconv,krait,kryo,ldp-aligned-only,lob,log-vrgather,long-calls,loop-align,lor,ls64,lscp,lse,lse128,lse2,lsfe,lsui,lut,m,m3,m55,m7,m85,max-interleave-factor-4,mca-streaming-sched,mclass,mec,mips-p8700,mops,mops-go,mp,mpam,mte,mtetc,multimemory,multivalue,mutable-globals,muxed-units,mve,mve.fp,mve1beat,mve2beat,mve4beat,neon,neon-fpmovs,neonfp,neoverse-v1,neoverse512tvb,neoversee1,neoversen1,neoversen2,neoversen3,neoversev1,neoversev2,neoversev3,neoversev3AE,nmi,no-branch-predictor,no-bti-at-return-twice,no-default-unroll,no-lfi-loads,no-lfi-stores,no-movt,no-neg-immediates,no-sink-splat-operands,no-sve-fp-ld1r,no-trailing-seq-cst-fence,no-zcz-fpr64,noarm,nonpipelined-vfp,nontrapping-fptoint,nv,occmo,olympus,optimized-nf2-segment-load-store,optimized-nf3-segment-load-store,optimized-nf4-segment-load-store,optimized-nf5-segment-load-store,optimized-nf6-segment-load-store,optimized-nf7-segment-load-store,optimized-nf8-segment-load-store,optimized-zero-stride-load,oryon-1,outline-atomics,pacbti,pan,pan-rwv,pauth,pauth-lr,perfmon,permissive-zalrsc,poe2,pops,predictable-select-expensive,predres,prefer-ascending-load-store,prefer-ishst,prefer-vmovsr,prefer-vsetvli-over-read-vlenb,prefer-w-inst,prfm-slc-target,prof-unpr,q,r4,r5,r52,r52plus,r7,rand,ras,rasv2,rclass,rcpc,rcpc-immo,rcpc3,rdm,read-tp-tpidrprw,read-tp-tpidruro,read-tp-tpidrurw,reference-types,relax,relaxed-atomics,relaxed-simd,reserve-lr-for-ra,reserve-x1,reserve-x10,reserve-x11,reserve-x12,reserve-x13,reserve-x14,reserve-x15,reserve-x16,reserve-x17,reserve-x18,reserve-x19,reserve-x2,reserve-x20,reserve-x21,reserve-x22,reserve-x23,reserve-x24,reserve-x25,reserve-x26,reserve-x27,reserve-x28,reserve-x29,reserve-x3,reserve-x30,reserve-x31,reserve-x4,reserve-x5,reserve-x6,reserve-x7,reserve-x8,reserve-x9,ret-addr-stack,rme,rva20s64,rva20u64,rva22s64,rva22u64,rva23s64,rva23u64,rvb23s64,rvb23u64,rvi20u32,rvi20u64,saphira,save-restore,sb,sdext,sdtrig,sel2,sha2,sha3,shcounterenw,shgatpa,shlcofideleg,short-forward-branch-ialu,short-forward-branch-iload,short-forward-branch-iminmax,short-forward-branch-imm,short-forward-branch-imul,shtvala,shvsatpa,shvstvala,shvstvecd,sifive7,sign-ext,simd128,single-element-vec-fp64,slow-fp-brcc,slow-load-D-subreg,slow-misaligned-128store,slow-odd-reg,slow-paired-128,slow-strqro-store,slow-vdup32,slow-vgetlni32,slowfpvfmx,slowfpvmlx,smaia,smcdeleg,smcntrpmf,smcsrind,smctr,smdbltrp,sme,sme-b16b16,sme-f16f16,sme-f64f64,sme-f8f16,sme-f8f32,sme-fa64,sme-i16i64,sme-lutv2,sme-mop4,sme-tmop,sme2,sme2p1,sme2p2,sme2p3,smepmp,smmpm,smnpm,smrnmi,smstateen,spe,spe-eef,specres2,specrestrict,splat-vfp-neon,ssaia,ssbs,ssccfg,ssccptr,sscofpmf,sscounterenw,sscsrind,ssctr,ssdbltrp,ssnpm,sspm,ssqosid,ssstateen,ssstrict,sstc,sstvala,sstvecd,ssu64xl,ssve-aes,ssve-bitperm,ssve-fexpa,ssve-fp8dot2,ssve-fp8dot4,ssve-fp8fma,store-pair-suppress,stp-aligned-only,strict-align,supm,svade,svadu,svbare,sve,sve-aes,sve-aes2,sve-b16b16,sve-b16mm,sve-bfscale,sve-bitperm,sve-f16f32mm,sve-sha3,sve-sm4,sve2,sve2-aes,sve2-bitperm,sve2-sha3,sve2-sm4,sve2p1,sve2p2,sve2p3,svinval,svnapot,svpbmt,svrsw60t59b,svvptc,swift,tail-call,tev,the,thumb-mode,thumb2,thunderx,thunderx2t99,thunderx3t110,thunderxt81,thunderxt83,thunderxt88,tlb-rmi,tlbid,tlbiw,tpidr-el1,tpidr-el2,tpidr-el3,tpidrro-el0,tracev8.4,trbe,trustzone,tsv110,uaops,unaligned-scalar-mem,unaligned-vector-mem,use-experimental-zeroing-pseudos,use-fixed-over-scalable-if-equal-cost,use-mipipeliner,use-misched,use-postra-scheduler,use-reciprocal-square-root,use-wzr-to-vec-move,v,v4t,v5t,v5te,v6,v6k,v6m,v6t2,v7,v7clrex,v8,v8.1a,v8.1m.main,v8.2a,v8.3a,v8.4a,v8.5a,v8.6a,v8.7a,v8.8a,v8.9a,v8a,v8m,v8m.main,v8r,v9.1a,v9.2a,v9.3a,v9.4a,v9.5a,v9.6a,v9.7a,v9a,ventana-veyron,vfp2,vfp2sp,vfp3,vfp3d16,vfp3d16sp,vfp3sp,vfp4,vfp4d16,vfp4d16sp,vfp4sp,vh,virtualization,vl-dependent-latency,vldn-align,vmlx-forwarding,vmlx-hazards,vxrm-pipeline-flush,wfxt,wide-arithmetic,wide-stride-vfp,xaifet,xandesbfhcvt,xandesperf,xandesvbfhcvt,xandesvdot,xandesvpackfph,xandesvsinth,xandesvsintload,xcheriot,xcvalu,xcvbi,xcvbitmanip,xcvelw,xcvmac,xcvmem,xcvsimd,xmipscbop,xmipscmov,xmipsexectl,xmipslsp,xqccmp,xqci,xqcia,xqciac,xqcibi,xqcibm,xqcicli,xqcicm,xqcics,xqcicsr,xqciint,xqciio,xqcilb,xqcili,xqcilia,xqcilo,xqcilsm,xqcisim,xqcisls,xqcisync,xs,xscale,xsfcease,xsfmm128t,xsfmm16t,xsfmm32a,xsfmm32a16f,xsfmm32a32f,xsfmm32a8f,xsfmm32a8i,xsfmm32t,xsfmm64a64f,xsfmm64t,xsfmmbase,xsfvcp,xsfvfbfexp16e,xsfvfexp16e,xsfvfexp32e,xsfvfexpa,xsfvfexpa64e,xsfvfnrclipxfqf,xsfvfwmaccqqq,xsfvqmaccdod,xsfvqmaccqoq,xsifivecdiscarddlone,xsifivecflushdlone,xsmtvdot,xsmtvdotii,xtheadba,xtheadbb,xtheadbs,xtheadcmo,xtheadcondmov,xtheadfmemidx,xtheadmac,xtheadmemidx,xtheadmempair,xtheadsync,xtheadvdot,xventanacondops,xwchc,za128rs,za64rs,zaamo,zabha,zacas,zalasr,zalrsc,zama16b,zawrs,zba,zbb,zbc,zbkb,zbkc,zbkx,zbs,zca,zcb,zcd,zce,zcf,zclsd,zcm-fpr128,zcm-fpr32,zcm-fpr64,zcm-gpr32,zcm-gpr64,zcmop,zcmp,zcmt,zcz,zcz-fp-workaround,zcz-fpr128,zcz-gpr32,zcz-gpr64,zdinx,zfa,zfbfmin,zfh,zfhmin,zfinx,zhinx,zhinxmin,zic64b,zicbom,zicbop,zicboz,ziccamoa,ziccamoc,ziccid,ziccif,zicclsm,ziccrse,zicntr,zicond,zicsr,zifencei,zihintntl,zihintpause,zihpm,zilsd,zilsd-word-align,zimop,zk,zkn,zknd,zkne,zknh,zkr,zks,zksed,zksh,zkt,zmmul,ztso,zvbb,zvbc,zve32f,zve32x,zve64d,zve64f,zve64x,zvfbfmin,zvfbfwma,zvfh,zvfhmin,zvkb,zvkg,zvkn,zvknc,zvkned,zvkng,zvknha,zvknhb,zvks,zvksc,zvksed,zvksg,zvksh,zvkt,zvl1024b,zvl128b,zvl16384b,zvl2048b,zvl256b,zvl32768b,zvl32b,zvl4096b,zvl512b,zvl64b,zvl65536b,zvl8192b"
	remaining := x86_names
	for candidate in strings.split_iterator(&remaining, ",") {
		if candidate == name { return true }
	}
	if x86_only { return false }
	remaining = other_names
	for candidate in strings.split_iterator(&remaining, ",") {
		if candidate == name { return true }
	}
	return false
}
