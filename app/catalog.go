package main

import (
	"dropocore/catalog"
	"time"
)

func (a *App) ValidateManagedCatalog(raw string, minimum int64) map[string]interface{} {
	p, err := catalog.Verify([]byte(raw), minimum, time.Now())
	if err != nil {
		return map[string]interface{}{"success": false, "error": "Каталог Dropo не прошёл проверку подписи."}
	}
	return map[string]interface{}{"success": true, "revision": p.Revision}
}
