package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"

	"github.com/qjam/bvx/engine/engine"
)

// bvx_probe reports whether a path holds bead data, without opening it.
//
// Session-less on purpose. The Open panel asks about every directory the user
// browses past, and opening a session per folder would run a full analysis to
// answer a yes/no question.
//
// It is also why the panel and the loader cannot disagree: both answers come
// from engine.Probe, so a folder the panel offers is one the loader accepts.
//
//export bvx_probe
func bvx_probe(path *C.char) *C.char {
	if path == nil {
		return envelope(nil, 0, fmt.Errorf("probe requires a path"))
	}
	raw, err := json.Marshal(engine.Probe(C.GoString(path)))
	if err != nil {
		return envelope(nil, 0, err)
	}
	return envelope(json.RawMessage(raw), 0, nil)
}
