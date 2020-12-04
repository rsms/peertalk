#ifndef PT_PRECISE_LIFETIME
  #define PT_PRECISE_LIFETIME __attribute__((objc_precise_lifetime))
#endif

#ifndef PT_PRECISE_LIFETIME_UNUSED
	#define PT_PRECISE_LIFETIME_UNUSED __attribute__((objc_precise_lifetime, unused))
#endif
