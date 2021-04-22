#include <sourcemod>
#include <freak_fortress_2>
#include <freak_fortress_2_subplugin>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
    name="Freak Fortress difficulty forwarder",
    author="Nitros",
    description="FF2: Forwards difficulty via a forward",
    version="0.1.0",
    url="ben@bensimms.moe"
};

GlobalForward difficulty_forward = null;

public void OnPluginStart2() {
    LogError("[FF2DiffForward] starting up");
    difficulty_forward = new GlobalForward("OnFF2Difficulty", ET_Event, Param_Cell, Param_String, Param_Cell);
}

public void FF2_OnDifficulty(int boss, const char[] section, Handle kv) {
    LogError("[FF2DiffForward] Forwarding difficulty for boss %d", boss);

    Call_StartForward(difficulty_forward);

    Call_PushCell(boss);
    Call_PushString(section);
    Call_PushCell(kv);

    Call_Finish();
}
