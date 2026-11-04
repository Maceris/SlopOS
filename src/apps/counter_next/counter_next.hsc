/**
 * The counter, version 2 (roadmap 9d4, decisions/0117): counter_app's run, for testing installations.
 */
package counter_next

import config from "../../protocols/config"
import installations from "../../installations"
import counter_app from "../../counter_app"

/**
 * Count this run in the app's data, say which run and version it is, then keep running until asked to stop.
 *
 * Each run adds the configured step (1 unless the settings say otherwise) to the number in the data directory's file
 * count, writes it back, and logs the run's number and that version 2 counted it; an update that keeps the data counts
 * on, and an uninstall starts again from 1. It then waits until the lifecycle channel asks it to stop.
 *
 * @param data The installation's data directory, where the file count is kept; closed when the run ends.
 * @param settings A connection to the config store, through which the counter declares its settings and reads its step.
 *     Without it, each run counts 1.
 * @return 0 once it's asked to stop; 1 if a port for the settings couldn't be made, 2 if the data directory couldn't be
 *     opened, 3 if the count couldn't be written, 4 if it couldn't wait to be asked to stop.
 */
main :: fn(data: installations.AppData, settings: config.Config[counter_app.CounterSettings]?) -> int {
    return counter_app.run(data, settings, 2)
}
