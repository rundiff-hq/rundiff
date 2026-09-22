package metrics

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sort"
)

type Summary struct {
	Implementation string
	Phase          string
	Role           string
	Count          int
	MedianMillis   int64
	P95Millis      int64
	MinMillis      int64
	MaxMillis      int64
}

type summaryKey struct {
	implementation string
	phase          string
	role           string
}

func SummarizeFiles(paths []string) ([]Summary, error) {
	grouped := map[summaryKey][]int64{}

	for _, path := range paths {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			var event Event
			if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
				file.Close()
				return nil, fmt.Errorf("%s: %w", path, err)
			}
			key := summaryKey{
				implementation: event.Implementation,
				phase:          event.Phase,
				role:           event.Role,
			}
			grouped[key] = append(grouped[key], event.DurationMillis)
		}
		if err := scanner.Err(); err != nil {
			file.Close()
			return nil, err
		}
		if err := file.Close(); err != nil {
			return nil, err
		}
	}

	summaries := make([]Summary, 0, len(grouped))
	for key, values := range grouped {
		sort.Slice(values, func(i, j int) bool { return values[i] < values[j] })
		summaries = append(summaries, Summary{
			Implementation: key.implementation,
			Phase:          key.phase,
			Role:           key.role,
			Count:          len(values),
			MedianMillis:   percentile(values, 0.50),
			P95Millis:      percentile(values, 0.95),
			MinMillis:      values[0],
			MaxMillis:      values[len(values)-1],
		})
	}

	sort.Slice(summaries, func(i, j int) bool {
		left := summaries[i]
		right := summaries[j]
		if left.Implementation != right.Implementation {
			return left.Implementation < right.Implementation
		}
		if left.Phase != right.Phase {
			return left.Phase < right.Phase
		}
		return left.Role < right.Role
	})

	return summaries, nil
}

func percentile(sorted []int64, fraction float64) int64 {
	if len(sorted) == 0 {
		return 0
	}
	index := int(float64(len(sorted)-1)*fraction + 0.5)
	if index < 0 {
		index = 0
	}
	if index >= len(sorted) {
		index = len(sorted) - 1
	}
	return sorted[index]
}
