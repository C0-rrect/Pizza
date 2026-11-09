#import <Security/Authorization.h>
#import <Security/AuthorizationTags.h>
#import <stdio.h>
#import <string.h>

// One-shot privileged processes; reuse the OS authorization reference while this app is open.
// No password is read or stored, no persistent privileged daemon is installed.
int PizzaAuthorizeWriter(const char *tool,const char *mode,const char *request,char *result,size_t capacity) {
    static AuthorizationRef authorization=NULL;
    OSStatus status=authorization ? errAuthorizationSuccess : AuthorizationCreate(NULL,kAuthorizationEmptyEnvironment,kAuthorizationFlagDefaults,&authorization);
    if(status!=errAuthorizationSuccess)return status;
    AuthorizationItem item={kAuthorizationRightExecute,strlen(tool),(void *)tool,0};
    AuthorizationRights rights={1,&item};
    status=AuthorizationCopyRights(authorization,&rights,kAuthorizationEmptyEnvironment,kAuthorizationFlagInteractionAllowed|kAuthorizationFlagExtendRights,NULL);
    if(status!=errAuthorizationSuccess){return status;}
    char *arguments[]={(char *)mode,(char *)request,NULL};FILE *pipe=NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    status=AuthorizationExecuteWithPrivileges(authorization,tool,kAuthorizationFlagDefaults,arguments,&pipe);
#pragma clang diagnostic pop
    if(status==errAuthorizationSuccess && pipe){
        size_t used=0;int c;
        while((c=fgetc(pipe))!=EOF){if(used+1<capacity)result[used++]=(char)c;}
        result[used]=0;fclose(pipe);
    }
    
    return status;
}
