// Umbrella-Header für System-TagLib. Wir nutzen nur die C-API-Deklarationen
// als Modul-Anker; der eigentliche Zugriff passiert im C++-Shim (CTagShim),
// der über dieselben pkg-config-Flags die C++-Header einbindet.
#include <tag_c.h>
