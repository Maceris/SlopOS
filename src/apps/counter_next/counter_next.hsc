/**
 * The counter, version 2 (roadmap 9d4, decisions/0117): counter_app's run, for testing installations.
 */
package counter_next

import config from "../../protocols/config"
import installations from "../../installations"
import counter_app from "../../counter_app"

main :: fn(data: installations.AppData, settings: config.Config[counter_app.CounterSettings]?) -> int {
    return counter_app.run(data, settings, 2)
}
