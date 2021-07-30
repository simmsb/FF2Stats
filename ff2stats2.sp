#include <sourcemod>
#include <tf2_stocks>
#include <freak_fortress_2>
#include <clientprefs>
#include <convars>
#include <dbi>
#include <menus>
#include <ff2diffforward>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION

#define BOSS_RESULTS_TABLE "ff2stats2_bossresults"
#define PLAYER_STATS_TABLE "ff2stats2_playerstats"

public Plugin myinfo = {
    name="Freak Fortress Stats",
    author="Nitros",
    description="Boss stats for freak fortress 2",
    version="0.3.0",
    url="ben@bensimms.moe"
};

enum struct PlayerInfo {
    bool active;
    int client;
    int kills;
    bool stats_enabled;
    int difficulty;
    bool mod_applied;
    TFClassType class;

    void joined(int client) {
        this.active = true;
        this.client = client;
        this.kills = 0;
        this.stats_enabled = false;
        this.difficulty = 0;
        this.mod_applied = false;
        this.class = TFClass_Unknown;
    }

    void left() {
        this.active = false;
    }

    void reset() {
        this.kills = 0;
        this.stats_enabled = false;
        this.difficulty = 0;
        this.mod_applied = false;
        this.class = TFClass_Unknown;
    }
}

PlayerInfo players[MAXPLAYERS+1];

bool round_end_counted = false;

Database db_conn = null;
Cookie pref_cookie = null;
ConVar is_enabled = null;
ConVar min_rounds = null;
ConVar max_hp_mod_pct = null;
ConVar min_players = null;
ConVar map_mod_scale = null;
ConVar modifier_scale = null;


// PLAYER STATE MANAGEMENT

void init_players() {
    for (int i = 0; i < MAXPLAYERS; i++) {
        players[i].left();
    }
}

void reset_players() {
    for (int i = 0; i < MAXPLAYERS; i++) {
        players[i].reset();
    }
}


// SOURCEMOD CALLBACKS

public void OnPluginStart() {
    Database.Connect(start_db_cb);
    pref_cookie = new Cookie("ff2stats2_enabled", "Enable counting personal boss stats for user.", CookieAccess_Public);

    is_enabled = CreateConVar("ff2stats2_enabled", "1.0", "Enable or disable ff2stats globally", FCVAR_PROTECTED, true, 0.0, true, 1.0);
    min_rounds = CreateConVar("ff2stats2_minrounds", "10.0", "Minimum rounds before a hp mod is applied", FCVAR_PROTECTED, true, 0.0, false, _);
    max_hp_mod_pct = CreateConVar("ff2stats2_max_hp_mod_pct", "0.3", "Maximum hp mod as a fraction", FCVAR_PROTECTED, true, 0.0, false, _);
    min_players = CreateConVar("ff2stats2_min_players", "6.0", "Minimum players needed for ff2stats to track stats", FCVAR_PROTECTED, true, 0.0, false, _);
    map_mod_scale = CreateConVar("ff2stats2_map_mod_scale", "0.1", "How much to scale the map hp mod by", FCVAR_PROTECTED, true, 0.0, false, _);
    modifier_scale = CreateConVar("ff2stats2_modifier_scale", "1.0", "Arbitrary value to sclae hp mods by", FCVAR_PROTECTED, true, 0.0, false, _);

    HookEvent("teamplay_round_start", on_round_start);
    HookEvent("teamplay_round_win", on_round_win);
    HookEvent("teamplay_round_stalemate", on_round_stalemate);
    RegConsoleCmd("ff2stats", ff2stats_cmd_cb, "View the FF2Stats menu");
    // RegConsoleCmd("top10", top10_cmd_cb, "View the leaderboard menu");

    init_players();
}

public void OnMapStart() {
    CreateTimer(45.0, command_notif_timer_cb, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client) {
    if (!should_track_stats())
        return;

    if (!were_stats_enabled_for(client))
        return;

    // player left mid-round, count a player-only loss

    int steam_id = GetSteamAccountID(client);
    if (steam_id <= 0)
        return;

    int boss = FF2_GetBossIndex(client);

    if (boss == -1)
        return;

    char boss_name[255];
    FF2_GetBossSpecial(boss, boss_name, sizeof(boss_name));
    CPrintToChatAll("{olive}[FF2stats]{default} A boss left the game while it was their turn and a loss was counted.");

    add_round_to_db_player_boss(steam_id, boss_name, 0, false, 0);
}


// FF2 CALLBACKS

public void OnFF2Difficulty(int boss, const char[] difficulty, Handle kv) {
    LogError("[FF2Stats] diff: %d, %s", boss, difficulty);
    int userid = FF2_GetBossUserId(boss);

    if (userid == -1)
        return;

    int client = GetClientOfUserId(userid);

    if (!IsValidClient(client))
        return;

    players[client].difficulty = difficulty_as_int(difficulty);
}

// DB INIT

public void start_db_cb(Database db, const char[] error, any data) {
    if (db == null) {
        SetFailState(error);
    }

    db_conn = db;

    ArrayStack queries = new ArrayStack(255 * 5);
    queries.PushString("CREATE TABLE IF NOT EXISTS ff2stats2_mapbossresults (bossname TEXT, map TEXT, win INT, INDEX (bossname(20), map(20)))");
    queries.PushString("CREATE TABLE IF NOT EXISTS ff2stats2_personalbossresults (steamid INT, bossname TEXT, kills INT, win INT, points INT, INDEX (steamid, bossname(20)))");
    queries.PushString("CREATE TABLE IF NOT EXISTS ff2stats2_playerstats (steamid INT, class INT, damage_done INT, map TEXT, round_time INT, INDEX (steamid, class, map(20)))");

    run_all_queries(queries);
}

void run_all_queries(ArrayStack queries) {
    char query[255];

    queries.PopString(query, sizeof(query));

    db_conn.Query(db_query_chain_cb, query, queries);
}

public void db_query_chain_cb(Database db, DBResultSet results, const char[] error, any data) {
    if (db == null || results == null) {
        LogError("[FF2Stats] Query failed: %s", error);
        return;
    }

    ArrayStack queries = data;

    if (queries.Empty)
        return;

    char query[255];

    queries.PopString(query, sizeof(query));

    db_conn.Query(db_query_chain_cb, query, queries);
}

// UTILS

int count_players() {
    int count = 0;
    for(int client = 1; client <= MaxClients; client++) {
        if (IsValidClient(client) && !IsFakeClient(client)) {
            count++;
        }
    }
    return count;
}

bool enough_players() {
    return (count_players() >= min_players.IntValue);
}

bool should_track_stats() {
    return (FF2_IsFF2Enabled() && is_enabled.BoolValue && enough_players());
}

void toggle_stats_cookie(int client) {
    if (!IsValidClient(client) || IsFakeClient(client) || !AreClientCookiesCached(client)) {
        return;
    }

    bool state = stats_enabled_for(client);

    char s_value[4];
    IntToString(!state, s_value, sizeof(s_value));

    pref_cookie.Set(client, s_value);
}

// if stats are enabled for this player
bool stats_enabled_for(int client) {
    if (!AreClientCookiesCached(client))
        return false;

    char s_value[4];
    pref_cookie.Get(client, s_value, sizeof(s_value));

    if (s_value[0] == '\0')
        return true;

    return StringToInt(s_value) == 1;
}

// if stats were enabled for this player this round
bool were_stats_enabled_for(int client) {
    return players[client].stats_enabled;
}


// DB STUFF

public void null_cb(Database db, DBResultSet results, const char[] error, any data) {
    if (db == null || results == null) {
        LogError("[FF2Stats] Query failed: %s", error);
    }
}

void add_round_to_db_merc(int steam_id, int class, const char[] map_name, int damage, float round_time) {
    char query[255];

    db_conn.Format(query, sizeof(query), "INSERT INTO ff2stats2_playerstats (steamid, class, damage_done, map, round_time) VALUES (%d, %d, %d, '%s', %f)",
        steam_id, class, damage, map_name, round_time);

    db_conn.Query(null_cb, query, _);
}

void add_round_to_db_map_boss(const char[] boss_name, const char[] map_name, bool boss_won) {
    char query[255];

    db_conn.Format(query, sizeof(query), "INSERT INTO ff2stats2_mapbossresults (bossname, map, win) VALUES ('%s', '%s', %d)",
        boss_name, map_name, boss_won);

    db_conn.Query(null_cb, query, _);
}

void add_round_to_db_player_boss(int steam_id, const char[] boss_name, int kills, bool boss_won, int points) {
    char query[255];

    db_conn.Format(query, sizeof(query), "INSERT INTO ff2stats2_personalbossresults (steamid, bossname, kills, win, points) VALUES (%d, '%s', %d, %d, %d)",
        steam_id, boss_name, kills, boss_won, points);

    db_conn.Query(null_cb, query, _);
}

void get_player_wins_as_boss(int steam_id, const char[] boss_name, int &wins, int &losses) {
    char query[255];

    db_conn.Format(query, sizeof(query), "SELECT sum(win), count(win) - sum(win) FROM ff2stats2_personalbossresults WHERE steamid = %d AND bossname = '%s'",
        steam_id, boss_name);

    SQL_LockDatabase(db_conn);
    DBResultSet res = SQL_Query(db_conn, query);
    SQL_UnlockDatabase(db_conn);

    if (res == null) {
        wins = 0;
        losses = 0;
        return;
    }

    res.FetchRow();

    wins = res.FetchInt(0);
    losses = res.FetchInt(1);

    delete res;
}

void get_map_wins_as_boss(const char[] boss_name, const char[] map_name, int &wins, int &losses) {
    char query[255];

    db_conn.Format(query, sizeof(query), "SELECT sum(win), count(win) - sum(win) FROM ff2stats2_mapbossresults WHERE map = '%s' AND bossname = '%s'",
        map_name, boss_name);

    SQL_LockDatabase(db_conn);
    DBResultSet res = SQL_Query(db_conn, query);
    SQL_UnlockDatabase(db_conn);

    if (res == null) {
        wins = 0;
        losses = 0;
        return;
    }

    res.FetchRow();

    wins = res.FetchInt(0);
    losses = res.FetchInt(1);

    delete res;
}

void clear_player_boss_stats(int steam_id) {
    char query[255];

    db_conn.Format(query, sizeof(query), "DELETE FROM ff2stats2_personalbossresults where steamid = %d", steam_id);

    db_conn.Query(null_cb, query, _);
}

void clear_player_merc_stats(int steam_id) {
    char query[255];

    db_conn.Format(query, sizeof(query), "DELETE FROM ff2stats2_playerstats where steamid = %d", steam_id);

    db_conn.Query(null_cb, query, _);
}

typedef boss_stats_cb = function void(int client, DBResultSet results);
typedef merc_stats_cb = function void(int client, DBResultSet results);

public void get_stats_cb(Database db, DBResultSet results, const char[] error, any data) {
    if (db == null || results == null) {
        LogError("[FF2Stats] Query failed: %s", error);
        return;
    }

    DataPack dp = data;

    int client = dp.ReadCell();
    boss_stats_cb cb = view_as<boss_stats_cb>(dp.ReadFunction());

    delete dp;

    Call_StartFunction(null, cb);
    Call_PushCell(client);
    Call_PushCell(results);
    Call_Finish();
}

void get_boss_stats(int client, boss_stats_cb cb) {
    char query[255];

    int steam_id = GetSteamAccountID(client);

    db_conn.Format(query, sizeof(query), "SELECT bossname, sum(win), count(win) - sum(win), sum(kills), sum(points) FROM ff2stats2_personalbossresults where steamid = %d GROUP BY bossname",
        steam_id);

    DataPack dp = new DataPack();
    dp.WriteCell(client);
    dp.WriteFunction(cb);
    dp.Reset();

    db_conn.Query(get_stats_cb, query, dp);
}

void get_merc_stats_perclass(int client, merc_stats_cb cb) {
    char query[255];

    int steam_id = GetSteamAccountID(client);

    db_conn.Format(query, sizeof(query), "SELECT class, sum(damage_done), sum(round_time) FROM ff2stats2_playerstats where steamid = %d GROUP BY class ORDER BY class",
        steam_id);

    DataPack dp = new DataPack();
    dp.WriteCell(client);
    dp.WriteFunction(cb);
    dp.Reset();

    db_conn.Query(get_stats_cb, query, dp);
}

// MENU STUFF

public int confirm_clear_boss_stats_menu_cb(Menu menu, MenuAction action, int client, int selection) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }

        case MenuAction_Select: {
            char info[4];
            menu.GetItem(selection, info, sizeof(info));

            if (strcmp("y", info) == 0) {
                clear_player_boss_stats(GetSteamAccountID(client));
                CPrintToChat(client, "{olive}[FF2stats]{default} Your boss stats have been reset!");
            } else {
                CPrintToChat(client, "{olive}[FF2stats]{default} Your boss stats have NOT been cleared!");
            }
        }
    }
}

void confirm_clear_boss_stats_menu(int client) {
    Menu m = new Menu(confirm_clear_boss_stats_menu_cb);
    m.SetTitle("Are you sure you want to clear your boss stats?");
    m.AddItem("y", "Yes");
    m.AddItem("n", "No");
    m.ExitBackButton = true;
    m.Display(client, 10);
}


public int confirm_clear_merc_stats_menu_cb(Menu menu, MenuAction action, int client, int selection) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }

        case MenuAction_Select: {
            char info[4];
            menu.GetItem(selection, info, sizeof(info));

            if (strcmp("y", info) == 0) {
                clear_player_merc_stats(GetSteamAccountID(client));
                CPrintToChat(client, "{olive}[FF2stats]{default} Your merc stats have been reset!");
            } else {
                CPrintToChat(client, "{olive}[FF2stats]{default} Your merc stats have NOT been cleared!");
            }
        }
    }
}

void confirm_clear_merc_stats_menu(int client) {
    Menu m = new Menu(confirm_clear_merc_stats_menu_cb);
    m.SetTitle("Are you sure you want to clear your merc stats?");
    m.AddItem("y", "Yes");
    m.AddItem("n", "No");
    m.ExitBackButton = true;
    m.Display(client, 10);
}


public int ff2stats_null_menu_cb(Menu menu, MenuAction action, int client, int selection) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }
    }
}

public void ff2stats_view_boss_menu_data_cb(int client, DBResultSet results) {
    Menu m = new Menu(ff2stats_null_menu_cb);

    int total_wins = 0;
    int total_losses = 0;
    int total_kills = 0;
    int total_points = 0;

    char display[255];
    bool no_results = true;

    while (results.MoreRows) {
        no_results = false;

        results.FetchRow();

        char boss_name[255];
        results.FetchString(0, boss_name, sizeof(boss_name));

        int wins = results.FetchInt(1);
        int losses = results.FetchInt(2);
        int kills = results.FetchInt(3);
        int points = results.FetchInt(4);

        total_wins += wins;
        total_losses += losses;
        total_kills += kills;
        total_points += points;

        Format(display, sizeof(display), "%s (%d wins, %d losses, %d kills, %d points)",
            boss_name, wins, losses, kills, points);

        m.AddItem(boss_name, display);
    }

    delete results;

    if (no_results) {
        CPrintToChat(client, "{olive}[FF2stats]{default} You have no boss stats yet");

        return;
    }

    Format(display, sizeof(display), "Boss Stats (totals: %d wins, %d losses, %d kills, %d poins)",
        total_wins, total_losses, total_kills, total_points);

    m.ExitBackButton = true;
    m.SetTitle(display);
    m.Display(client, 60);
}

char classnames[][] = {
    "Unknown",
    "Scout",
    "Soldier",
    "Pyro",
    "DemoMan",
    "Heavy",
    "Engineer",
    "Medic",
    "Sniper",
    "Spy"
};

int class_lookup[] = {
    0,
    1, // scout
    8, // sniper
    2, // soldier
    4, // demo
    7, // medic
    5, // heavy
    3, // pyro
    9, // spy
    6 // engineer
};

enum struct MercStat {
    int damage;
    int round_time;
}

public void ff2stats_view_merc_menu_data_cb(int client, DBResultSet results) {
    Menu m = new Menu(ff2stats_null_menu_cb);

    int total_damage = 0;
    int total_time = 0;

    char display[255];

    MercStat merc_stats[10];

    while (results.MoreRows) {
        results.FetchRow();

        int class = results.FetchInt(0);
        int damage = results.FetchInt(1);
        int round_time = results.FetchInt(2);

        total_damage += damage;
        total_time += round_time;

        merc_stats[class_lookup[class]].damage = damage;
        merc_stats[class_lookup[class]].round_time = round_time;
    }

    delete results;

    for (int i = 1; i < 10; i++) {
        Format(display, sizeof(display), "%s (%d damage, %d seconds in game)",
            classnames[i], merc_stats[i].damage, merc_stats[i].round_time);

        m.AddItem(classnames[i], display);
    }

    Format(display, sizeof(display), "Merc Stats (totals: %d damage, %d seconds in game)",
        total_damage, total_time);

    m.ExitBackButton = true;
    m.SetTitle(display);
    m.Display(client, 60);
}

void ff2stats_view_boss_menu(int client) {
    get_boss_stats(client, ff2stats_view_boss_menu_data_cb);
}

void ff2stats_view_merc_menu(int client) {
    get_merc_stats_perclass(client, ff2stats_view_merc_menu_data_cb);
}

public int ff2stats_menu_cb(Menu menu, MenuAction action, int client, int selection) {
    switch (action) {
        case MenuAction_End: {
            delete menu;
        }
        case MenuAction_Select: {
            char info[4];
            menu.GetItem(selection, info, sizeof(info));

            if (strcmp("tps", info) == 0) {
                toggle_stats_cookie(client);
                bool enabled = stats_enabled_for(client);
                CPrintToChat(client, "{olive}[FF2stats]{default} Your personal stats have been %s!", enabled ? "enabled" : "disabled");
            } else if (strcmp("vbs", info) == 0) {
                ff2stats_view_boss_menu(client);
            } else if (strcmp("vms", info) == 0) {
                ff2stats_view_merc_menu(client);
            } else if (strcmp("cbs", info) == 0) {
                confirm_clear_boss_stats_menu(client);
            } else if (strcmp("cms", info) == 0) {
                confirm_clear_merc_stats_menu(client);
            }
        }
    }
}

void ff2stats_menu(int client) {
    bool enabled = stats_enabled_for(client);

    char tps_msg[255];
    Format(tps_msg, sizeof(tps_msg), "Toggle personal stats (currently %s)", enabled ? "enabled" : "disabled");

    Menu m = new Menu(ff2stats_menu_cb);
    m.SetTitle("FF2Stats");
    m.AddItem("tps", tps_msg);
    m.AddItem("vbs", "View boss stats");
    m.AddItem("vms", "View merc stats");
    m.AddItem("cbs", "Clear boss stats");
    m.AddItem("cms", "Clear merc stats");
    m.Display(client, 60);
}


// COMMANDS


public Action ff2stats_cmd_cb(int client, int args) {
    if (!IsValidClient(client))
        return Plugin_Handled;

    ff2stats_menu(client);

    return Plugin_Handled;
}


// STATS UPDATING


public Action on_round_start(Event event, char[] name, bool dontBroadcast) {
    reset_players();
    round_end_counted = false;

    if (!should_track_stats())
        return Plugin_Continue;

    if (!enough_players()) {
        CPrintToChatAll("{olive}[FF2stats]{default} Less than %d players, stats are disabled for this round.", min_players.IntValue);
        return Plugin_Continue;
    }

    LogError("[FF2Stats] round started");

    CreateTimer(3.0, set_boss_hp_timer_cb, _, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Continue;
}

public Action on_round_stalemate(Event event, char[] name, bool dontBroadcast) {
    if (!should_track_stats()) {
        LogError("[FF2Stats] Not logging round stalemate, requirements not met.");
        return Plugin_Continue;
    }

    if (round_end_counted)
        return Plugin_Continue;

    round_end_counted = true;

    float round_time = event.GetFloat("round_time");

    char map_name[255];
    GetCurrentMap(map_name, sizeof(map_name));

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsValidClient(client) || !were_stats_enabled_for(client)) {
            continue;
        }

        int boss = FF2_GetBossIndex(client);

        if (boss == -1) {
            // handle players

            int steam_id = GetSteamAccountID(client);

            if (steam_id <= 0)
                continue;

            int damage = FF2_GetClientDamage(client);
            TFClassType class = TF2_GetPlayerClass(client);

            add_round_to_db_merc(steam_id, view_as<int>(class), map_name, damage, round_time);
        } else {
            CPrintToChat(client, "{olive}[FF2stats]{default} A stalemate was encountered, your personal stats will remain the same.");
        }
    }

    return Plugin_Continue;
}

public Action on_round_win(Event event, char[] name, bool dontBroadcast) {
    if (!should_track_stats()) {
        LogError("[FF2Stats] Not logging round win, requirements not met.");
        return Plugin_Continue;
    }

    if (round_end_counted)
        return Plugin_Continue;

    round_end_counted = true;

    float round_time = event.GetFloat("round_time");
    bool boss_won = event.GetInt("team") == FF2_GetBossTeam();

    char map_name[255];
    GetCurrentMap(map_name, sizeof(map_name));

    for (int client = 1; client <= MaxClients; client++) {
        if (!IsValidClient(client)) {
            continue;
        }

        int boss = FF2_GetBossIndex(client);

        if (boss == -1) {
            // handle players

            int steam_id = GetSteamAccountID(client);

            if (steam_id <= 0)
                continue;

            int damage = FF2_GetClientDamage(client);
            TFClassType class = players[client].class;

            if (class == TFClassType) {
                // don't record unknown classes
                continue;
            }

            add_round_to_db_merc(steam_id, view_as<int>(class), map_name, damage, round_time);

            continue;
        }

        // handle bosses

        char boss_name[255];
        FF2_GetBossSpecial(boss, boss_name, sizeof(boss_name));

        add_round_to_db_map_boss(boss_name, map_name, boss_won);

        if (!were_stats_enabled_for(client)) {
            CPrintToChatAll("{olive}[FF2stats]{default} A map-local boss %s was counted for %s.", boss_won ? "win" : "loss", boss_name);
            continue;
        }

        int steam_id = GetSteamAccountID(client);

        if (steam_id <= 0)
            continue;

        int points = boss_won ? difficulty_as_points(players[client].difficulty) : 0;

        add_round_to_db_player_boss(steam_id, boss_name, players[client].kills, boss_won, points);
        CPrintToChatAll("{olive}[FF2stats]{default} Personal FF2stats was enabled for %N, they gained %d points, and a %s was counted for %s.", client, points, boss_won ? "win" : "loss", boss_name);
    }

    return Plugin_Continue;
}

public Action on_player_death(Event event, char[] name, bool dontBroadcast) {
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidClient(attacker))
        return Plugin_Continue;

    players[attacker].kills += 1;

    return Plugin_Continue;
}


// HP MOD APPLYING


float F_CLAMP(float val, float min, float max) {
    if (val < min) {
        return min;
    } else if (val > max) {
        return max;
    } else {
        return val;
    }
}

// returns a hp mod as a float ranging from (-1.0, 1.0)
float calc_hp_mod(int win, int loss) {
    // The greater the distance between win and loss, the greater the increase
    // we don't want 1001 wins and 1000 losses to have a different mod than 11
    // wins and 10 losses

    // if wins and losses less than the min rounds, no modification
    if ((win + loss) < min_rounds.IntValue) {
        LogError("[FF2Stats] using zero modifier (rounds < %d)", min_rounds.IntValue);
        return 0.0;
    }

    // more wins -> lose hp, more losses -> gain hp
    float sign = win > loss ? -1.0 : 1.0;

    float scale = FloatAbs(Pow(float(win - loss) / 50.0, 3.0)) * modifier_scale.FloatValue;

    float multiplier = scale * sign;
    float max_multiplier = max_hp_mod_pct.FloatValue;

    float clamped_multiplier = F_CLAMP(multiplier, -max_multiplier, max_multiplier);

    LogError("[FF2Stats] multiplier before clamp: %f, after: %f", multiplier, clamped_multiplier);

    return clamped_multiplier;
}

int calc_final_hp_mod(float player_mod, float map_mod, int base_hp) {
    map_mod *= map_mod_scale.FloatValue;

    float final_mod = (1.0 + player_mod) * (1.0 + map_mod);

    return RoundFloat(final_mod * base_hp);
}

void apply_hp_mod(int client, int boss) {
    int boss_steamid = GetSteamAccountID(client); // steamid

    bool stats_enabled = stats_enabled_for(client);

    if (boss_steamid == 0) {  // dont break on invalid steamid
        stats_enabled = false;
    }

    char boss_name[255];
    FF2_GetBossSpecial(boss, boss_name, sizeof(boss_name));

    char map_name[255];
    GetCurrentMap(map_name, sizeof(map_name));

    int boss_hp = FF2_GetBossMaxHealth(boss);

    float player_mod = 0.0;
    int player_win = 0;
    int player_loss = 0;

    if (stats_enabled) {
        get_player_wins_as_boss(boss_steamid, boss_name, player_win, player_loss);
        player_mod = calc_hp_mod(player_win, player_loss);
        players[client].stats_enabled = true;
    }


    int map_win, map_loss;
    get_map_wins_as_boss(boss_name, map_name, map_win, map_loss);

    float map_mod = calc_hp_mod(map_win, map_loss);
    int new_hp = calc_final_hp_mod(player_mod, map_mod, boss_hp);

    float visual_difficulty_mod = difficulty_as_hp_mod(players[client].difficulty);
    int visual_initial_hp = RoundFloat(boss_hp * visual_difficulty_mod);
    int visual_final_hp = RoundFloat(new_hp * visual_difficulty_mod);

    int visual_hp_diff = visual_final_hp - visual_initial_hp;
    float mod_pct = 100.0 * (player_mod + map_mod);

    if (stats_enabled) {
        CPrintToChatAll("{olive}[FF2stats]{default} %N has FF2stats enabled and was given a health modifier of %d (%.2f%%)! (%d wins, %d losses) (%d map wins, %d map losses)",
            client, visual_hp_diff, mod_pct, player_win, player_loss, map_win, map_loss);
    } else {

        CPrintToChatAll("{olive}[FF2stats]{default} %N was given a health modifier of %d (%.2f%%)! (%d map wins, %d map losses)",
            client, visual_hp_diff, mod_pct, map_win, map_loss);
    }

    FF2_SetBossMaxHealth(boss, new_hp);
    FF2_SetBossHealth(boss, new_hp * FF2_GetBossMaxLives(boss));
    // also set boss health, because it likes to break it somewhere else
}


// TIMER CALLBACKS


public Action set_boss_hp_timer_cb(Handle timer) {
    for (int client = 1; client <= MaxClients; client++) {
        if (!IsValidClient(client)) {
            continue;
        }

        if (players[client].mod_applied) {
            continue;
        }

        players[client].mod_applied = true;

        int boss = FF2_GetBossIndex(client);
        if (boss == -1) {
            players[client].class = TF2_GetPlayerClass(client);
            continue;
        }

        apply_hp_mod(client, boss);
    }
}

public Action command_notif_timer_cb(Handle timer) {
    static int print_loop = 0;

    if (print_loop > 1) {
        print_loop = 0;
    }

    if (print_loop == 0) {
        CPrintToChatAll("{olive}[FF2stats]{default} Use the command !ff2stats to open the ff2stats menu.");
    } else if (print_loop == 1) {
        // CPrintToChatAll("{olive}[FF2stats]{default} Use the command !top10 to view the leaderboards.");
    }

    print_loop++;

    return Plugin_Continue;
}


// UTILS

int difficulty_as_points(int difficulty) {
    return difficulty * 2 + 1;
}

float difficulty_as_hp_mod(int difficulty) {
    switch (difficulty) {
        case 0: return 1.0;
        case 1: return 0.8;
        case 2: return 0.75;
        case 3: return 0.65;
        case 4: return 0.5;
        case 5: return 0.25;
        default: return 1.0;
    }
}

int difficulty_as_int(const char[] difficulty) {
    if (strcmp(difficulty, "Intermediate") == 0)
        return 1;

    if (strcmp(difficulty, "Difficult") == 0)
        return 2;

    if (strcmp(difficulty, "Lunatic") == 0)
        return 3;

    if (strcmp(difficulty, "Insane") == 0)
        return 4;

    if (strcmp(difficulty, "Godlike") == 0)
        return 5;

    return 0;
}

stock bool IsValidClient(int client, bool replaycheck=true) {
    if (client<=0 || client>MaxClients) {
        return false;
    }

    if (!IsClientInGame(client)) {
        return false;
    }

    if (GetEntProp(client, Prop_Send, "m_bIsCoaching")) {
        return false;
    }

    if (replaycheck) {
        if (IsClientSourceTV(client) || IsClientReplay(client)) {
            return false;
        }
    }
    return true;
}
