package ownedprofile

import (
	"slices"
	"time"
)

type SourceGroup struct {
	Primary int
	Relay   int // -1 for personal sources and profiles without a stored relay.
}

// Groups exposes one row per managed profile while personal subscriptions
// retain their position and identity. A stale relay cannot become a profile.
func Groups(sources []Source) []SourceGroup {
	relays := make(map[string]int, 2)
	for i, source := range sources {
		if IsReserve(source.Provider) {
			relays[Family(source.Provider)] = i
		}
	}
	groups := make([]SourceGroup, 0, len(sources))
	for i, source := range sources {
		if IsReserve(source.Provider) {
			continue
		}
		group := SourceGroup{Primary: i, Relay: -1}
		if relay, ok := relays[source.Provider]; ok {
			group.Relay = relay
		}
		groups = append(groups, group)
	}
	return groups
}

// Move returns physical indices in the new logical order. A legacy relay
// always moves with its owner. Orphaned metadata is retained for vault restore.
func Move(sources []Source, id string, to int) ([]int, bool) {
	groups := Groups(sources)
	from := slices.IndexFunc(groups, func(g SourceGroup) bool { return sources[g.Primary].ID == id })
	if from < 0 || to < 0 || to >= len(groups) {
		return nil, false
	}
	item := groups[from]
	groups = slices.Delete(groups, from, from+1)
	groups = slices.Insert(groups, to, item)
	order := make([]int, 0, len(sources))
	used := make([]bool, len(sources))
	for _, g := range groups {
		order = append(order, g.Primary)
		used[g.Primary] = true
		if g.Relay >= 0 && !used[g.Relay] {
			order = append(order, g.Relay)
			used[g.Relay] = true
		}
	}
	for i := range sources {
		if !used[i] {
			order = append(order, i)
		}
	}
	return order, true
}

type Candidate struct {
	FinlandRelayURI  string
	ID, OwnerID, URI string
	Index            int // -1 for a runtime-only direct reserve.
}

func Candidates(sources []Source, now time.Time) []Candidate {
	occupied := make(map[string]bool, len(sources))
	for _, source := range sources {
		occupied[source.ID] = true
	}
	result := make([]Candidate, 0, len(sources))
	for _, group := range Groups(sources) {
		primary := sources[group.Primary]
		if primary.Disabled || Expired(primary.Provider, primary.URI, now) {
			continue
		}
		if !IsPrimary(primary.Provider) {
			result = append(result, Candidate{ID: primary.ID, OwnerID: primary.ID, URI: primary.URI, Index: group.Primary})
			continue
		}
		for _, direct := range DirectReserves(primary.Provider, primary.URI, now) {
			if !occupied[direct.ID] {
				result = append(result, Candidate{ID: direct.ID, OwnerID: primary.ID, URI: direct.URI, Index: -1, FinlandRelayURI: direct.FinlandRelayURI})
			}
		}
	}
	return result
}
