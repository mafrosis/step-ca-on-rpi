{
	"type": {{ toJson .Type }},
	"keyId": {{ toJson .KeyID }},
	"principals": {{ toJson ((concat .Principals (list "mafro" "pi")) | uniq) }},
	"extensions": {{ toJson .Extensions }},
	"criticalOptions": {{ toJson .CriticalOptions }}
}
